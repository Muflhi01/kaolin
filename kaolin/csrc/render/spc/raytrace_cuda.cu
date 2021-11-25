// Copyright (c) 2021 NVIDIA CORPORATION & AFFILIATES.
// All rights reserved.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at

//    http://www.apache.org/licenses/LICENSE-2.0

// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#define CUB_NS_PREFIX namespace kaolin {
#define CUB_NS_POSTFIX }

#include <stdio.h>
#include <ATen/ATen.h>

#define CUB_STDERR
#include <cub/device/device_scan.cuh>

#include "../../spc_math.h"
#include "../../spc_utils.cuh"
#include "spc_render_utils.cuh"

namespace kaolin {

using namespace cub;
using namespace std;
using namespace at::indexing;

////////////////////////////////////////////////////////////////////////////////////////////////
/// Constants
////////////////////////////////////////////////////////////////////////////////////////////////

__constant__ uint VOXEL_ORDER[8][8] = {
    { 0, 1, 2, 4, 3, 5, 6, 7 },
    { 1, 0, 3, 5, 2, 4, 7, 6 },
    { 2, 0, 3, 6, 1, 4, 7, 5 },
    { 3, 1, 2, 7, 0, 5, 6, 4 },
    { 4, 0, 5, 6, 1, 2, 7, 3 },
    { 5, 1, 4, 7, 0, 3, 6, 2 },
    { 6, 2, 4, 7, 0, 3, 5, 1 },
    { 7, 3, 5, 6, 1, 2, 4, 0 }
};

////////////////////////////////////////////////////////////////////////////////////////////////
/// Kernels
////////////////////////////////////////////////////////////////////////////////////////////////

// This function will initialize the nuggets array with each ray pointing to the octree root
__global__ void
init_nuggets_cuda_kernel(
    uint num, 
    uint2* nuggets) {
  
  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num) {
    nuggets[tidx].x = tidx; // ray idx
    nuggets[tidx].y = 0;    // point idx
  }
}

// This function will iterate over the nuggets (ray intersection proposals) and determine if they 
// result in an intersection. If they do, the info tensor is populated with the # of child nodes
// as determined by the input octree.
__global__ void
decide_cuda_kernel(
    uint num, 
    point_data* points, 
    float3* ray_o, 
    float3* ray_d,
    uint2* nuggets, 
    uint* info, 
    uint8_t* octree, 
    uint level, 
    uint not_done) {

  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num) {
    uint ridx = nuggets[tidx].x;
    uint pidx = nuggets[tidx].y;
    point_data p = points[pidx];
    float3 o = ray_o[ridx];
    float3 d = ray_d[ridx];

    // Radius of voxel
    float r = 1.0 / ((float)(0x1 << level));
    
    // Transform to [-1, 1]
    const float3 vc = make_float3(
        fmaf(r, fmaf(2.0, p.x, 1.0), -1.0f),
        fmaf(r, fmaf(2.0, p.y, 1.0), -1.0f),
        fmaf(r, fmaf(2.0, p.z, 1.0), -1.0f));

    // Compute aux info (precompute to optimize)
    float3 sgn = ray_sgn(d);
    float3 ray_inv = make_float3(1.0 / d.x, 1.0 / d.y, 1.0 / d.z);

    // Perform AABB check
    if (ray_aabb(o, d, ray_inv, sgn, vc, r) > 0.0){
      // Count # of occupied voxels for expansion, if more levels are left
      info[tidx] = not_done ? __popc(octree[pidx]) : 1;      
    } else {
      info[tidx] = 0;
    }
  }
}

// This function will iterate over the nugget array, and for each nuggets stores the child indices of the
// nuggets (as defined by the octree tensor) 
__global__ void
subdivide_cuda_kernel(
    uint num, 
    uint2* nuggets_in, 
    uint2* nuggets_out, 
    float3* ray_o,
    point_data* points, 
    uint8_t* octree, 
    uint* exclusive_sum, 
    uint* info,
    uint* prefix_sum, 
    uint level) {
  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num && info[tidx]) {
    uint ridx = nuggets_in[tidx].x;
    int pidx = nuggets_in[tidx].y;
    point_data p = points[pidx];

    uint base_idx = prefix_sum[tidx];

    uint8_t o = octree[pidx];
    uint s = exclusive_sum[pidx];

    float scale = 1.0 / ((float)(0x1 << level));
    float3 org = ray_o[ridx];
    float x = (0.5f * org.x + 0.5f) - scale*((float)p.x + 0.5);
    float y = (0.5f * org.y + 0.5f) - scale*((float)p.y + 0.5);
    float z = (0.5f * org.z + 0.5f) - scale*((float)p.z + 0.5);

    uint code = 0;
    if (x > 0) code = 4;
    if (y > 0) code += 2;
    if (z > 0) code += 1;

    for (uint i = 0; i < 8; i++) {
      uint j = VOXEL_ORDER[code][i];
      if (o&(0x1 << j)) {
        uint cnt = __popc(o&((0x2 << j) - 1)); // count set bits up to child - inclusive sum
        nuggets_out[base_idx].y = s + cnt;
        nuggets_out[base_idx++].x = ridx;
      }
    }
  }
}

__global__ void
remove_duplicate_rays_cuda_kernel(
    uint num, 
    uint2* nuggets, 
    uint* info) {

  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num) {
    if (tidx == 0)
      info[tidx] = 1;
    else
      info[tidx] = nuggets[tidx - 1].x == nuggets[tidx].x ? 0 : 1;
  }
}

// This function will take the nugget array, and remove the zero pads
__global__ void
compactify_cuda_kernel(
    uint num, 
    uint2* nuggets_in, 
    uint2* nuggets_out,
    uint* info, 
    uint* prefix_sum) {

  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num && info[tidx])
    nuggets_out[prefix_sum[tidx]] = nuggets_in[tidx];
}

////////////////////////////////////////////////////////////////////////////////////////////////
/// CUDA Implementations
////////////////////////////////////////////////////////////////////////////////////////////////

uint raytrace_cuda_impl(
    at::Tensor octree,
    at::Tensor points,
    at::Tensor pyramid,
    at::Tensor exclusive_sum,
    at::Tensor ray_o,
    at::Tensor ray_d,
    at::Tensor nugget_buffers,
    uint max_level,
    uint target_level) {

  uint num = ray_o.size(0);
  at::Tensor info = at::zeros({KAOLIN_SPC_MAX_POINTS}, octree.options().dtype(at::kInt));
  at::Tensor prefix_sum = at::zeros({KAOLIN_SPC_MAX_POINTS}, octree.options().dtype(at::kInt));
  
  uint8_t* octree_ptr = octree.data_ptr<uint8_t>();
  point_data* points_ptr = reinterpret_cast<point_data*>(points.data_ptr<short>());
  uint* pyramid_ptr = (uint*)pyramid.data_ptr<int>();
  uint* pyramid_sum = pyramid_ptr + max_level + 2;
  uint*  exclusive_sum_ptr = reinterpret_cast<uint*>(exclusive_sum.data_ptr<int>());
  float3* ray_o_ptr = reinterpret_cast<float3*>(ray_o.data_ptr<float>());
  float3* ray_d_ptr = reinterpret_cast<float3*>(ray_d.data_ptr<float>());
  uint2* nugget_buffers_ptr = reinterpret_cast<uint2*>(nugget_buffers.data_ptr<int>());

  uint*  prefix_sum_ptr = reinterpret_cast<uint*>(prefix_sum.data_ptr<int>());
  uint* info_ptr = reinterpret_cast<uint*>(info.data_ptr<int>());
  
  void* temp_storage_ptr = NULL;
  uint64_t temp_storage_bytes = get_cub_storage_bytes(
          temp_storage_ptr, info_ptr, prefix_sum_ptr, KAOLIN_SPC_MAX_POINTS);
  at::Tensor temp_storage = at::zeros({(int64_t)temp_storage_bytes}, octree.options());
  temp_storage_ptr = (void*)temp_storage.data_ptr<uint8_t>();
  
  uint2*  nuggets[2];
  nuggets[0] = nugget_buffers_ptr;
  nuggets[1] = nugget_buffers_ptr + KAOLIN_SPC_MAX_POINTS;

  int osize = pyramid_sum[max_level];

  // Generate proposals (first proposal is root node)
  init_nuggets_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(num, nuggets[0]);

  uint cnt, buffer = 0;

  // set first element to zero
  CubDebugExit(cudaMemcpy(prefix_sum_ptr, &buffer, sizeof(uint),
                          cudaMemcpyHostToDevice));

  for (uint l = 0; l <= target_level; l++) {
    // Do the proposals hit?
    decide_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(
        num, points_ptr, ray_o_ptr, ray_d_ptr, nuggets[buffer], info_ptr, octree_ptr, l, target_level - l);
    CubDebugExit(DeviceScan::InclusiveSum(
        temp_storage_ptr, temp_storage_bytes, info_ptr,
        prefix_sum_ptr + 1, num)); //start sum on second element
    cudaMemcpy(&cnt, prefix_sum_ptr + num, sizeof(uint), cudaMemcpyDeviceToHost);

    if (cnt == 0 || cnt > KAOLIN_SPC_MAX_POINTS)
      break; // either miss everything, or exceed memory allocation

    // Subdivide if more levels remain, repeat
    if (l < target_level) {
      subdivide_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(
          num, nuggets[buffer], nuggets[(buffer + 1) % 2], ray_o_ptr, points_ptr,
          octree_ptr, exclusive_sum_ptr, info_ptr, prefix_sum_ptr, l);
    } else {
      compactify_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(
          num, nuggets[buffer], nuggets[(buffer + 1) % 2],
          info_ptr, prefix_sum_ptr);
    }

    CubDebugExit(cudaGetLastError());

    buffer = (buffer + 1) % 2;
    num = cnt;
  }

  return cnt;
}

uint remove_duplicate_rays_cuda_impl(
    at::Tensor nuggets,
    at::Tensor output) {
  
  int num = nuggets.size(0);
  at::Tensor info = at::zeros({num}, nuggets.options().dtype(at::kInt));
  at::Tensor prefix_sum = at::zeros({num}, nuggets.options().dtype(at::kInt));
  
  uint2* nuggets_ptr = reinterpret_cast<uint2*>(nuggets.data_ptr<int>());
  uint2* output_ptr = reinterpret_cast<uint2*>(output.data_ptr<int>());
  uint* info_ptr = reinterpret_cast<uint*>(info.data_ptr<int>());
  uint* prefix_sum_ptr = reinterpret_cast<uint*>(prefix_sum.data_ptr<int>());
  
  void* temp_storage_ptr = NULL;
  uint64_t temp_storage_bytes = get_cub_storage_bytes(
          temp_storage_ptr, info_ptr, prefix_sum_ptr, KAOLIN_SPC_MAX_POINTS);
  at::Tensor temp_storage = at::zeros({(int64_t)temp_storage_bytes}, nuggets.options());
  temp_storage_ptr = (void*)temp_storage.data_ptr<uint8_t>();

  uint cnt = 0;
  remove_duplicate_rays_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(num, nuggets_ptr, info_ptr);
  CubDebugExit(DeviceScan::ExclusiveSum(temp_storage_ptr, temp_storage_bytes, info_ptr, prefix_sum_ptr, num+1));
  cudaMemcpy(&cnt, prefix_sum_ptr + num, sizeof(uint), cudaMemcpyDeviceToHost);
  compactify_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(num, nuggets_ptr, output_ptr, info_ptr, prefix_sum_ptr);

  return cnt;

}

void mark_first_hit_cuda_impl(
    at::Tensor nuggets,
    at::Tensor info) {
    int num = nuggets.size(0);
    remove_duplicate_rays_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(
        num,
        reinterpret_cast<uint2*>(nuggets.data_ptr<int>()),
        reinterpret_cast<uint*>(info.data_ptr<int>()));
}

////////// generate rays //////////////////////////////////////////////////////////////////////////

__global__ void
generate_rays_cuda_kernel(
    uint num, 
    uint width, 
    uint height, 
    float4x4 tf,
    float3* ray_o, 
    float3* ray_d) {
  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num) {
    uint px = tidx % width;
    uint py = tidx / height;

    float4 a = mul4x4(make_float4(0.0f, 0.0f, 1.0f, 0.0f), tf);
    float4 b = mul4x4(make_float4(px, py, 0.0f, 1.0f), tf);
    // float3 org = make_float3(M.m[3][0], M.m[3][1], M.m[3][2]);

    ray_o[tidx] = make_float3(a.x, a.y, a.z);
    ray_d[tidx] = make_float3(b.x, b.y, b.z);
  }
}


void generate_primary_rays_cuda_impl(
    uint width, 
    uint height, 
    float4x4& tf,
    float3* ray_o, 
    float3* ray_d) {
  uint num = width*height;

  generate_rays_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(num, width, height, tf, ray_o, ray_d);
}


////////// generate shadow rays /////////


__global__ void
plane_intersect_rays_cuda_kernel(
    uint num, 
    float3* ray_o, 
    float3* ray_d,
    float3* output, 
    float4 plane, 
    uint* info) {
  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num) {
    float3 org = ray_o[tidx];
    float3 dir = ray_d[tidx];

    float a = org.x*plane.x +  org.y*plane.y +  org.z*plane.z +  plane.w;
    float b = dir.x*plane.x +  dir.y*plane.y +  dir.z*plane.z;

    if (fabs(b) > 1e-3) {
      float t = - a / b;
      if (t > 0.0f) {
        output[tidx] = make_float3(org.x + t*dir.x, org.y + t*dir.y, org.z + t*dir.z);
        info[tidx] = 1;
      } else {
        info[tidx] = 0;
      }
    } else {
      info[tidx] = 0;
    }
  }
}

__global__ void
compactify_shadow_rays_cuda_kernel(
    uint num, 
    float3* p_in, 
    float3* p_out, 
    uint* map,
    uint* info, 
    uint* prefix_sum) {

  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num && info[tidx]) {
    p_out[prefix_sum[tidx]] = p_in[tidx];
    map[prefix_sum[tidx]] = tidx;
  }
}

__global__ void
set_shadow_rays_cuda_kernel(
    uint num, 
    float3* src, 
    float3* dst, 
    float3 light) {

  uint tidx = blockDim.x * blockIdx.x + threadIdx.x;

  if (tidx < num) {
    dst[tidx] = normalize(src[tidx] - light);
    src[tidx] = light;
  }
}

uint generate_shadow_rays_cuda_impl(
    uint num,
    float3* ray_o,
    float3* ray_d,
    float3* src,
    float3* dst,
    uint* map,
    float3& light,
    float4& plane,
    uint* info,
    uint* prefix_sum) {
  
  // set up memory for DeviceScan calls
  void* temp_storage_ptr = NULL;
  uint64_t temp_storage_bytes = get_cub_storage_bytes(temp_storage_ptr, info, prefix_sum, num);
  at::Tensor temp_storage = at::zeros({(int64_t)temp_storage_bytes}, device(at::DeviceType::CUDA).dtype(at::kByte));
  temp_storage_ptr = (void*)temp_storage.data_ptr<uint8_t>();

  uint cnt = 0;
  plane_intersect_rays_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(
      num, ray_o, ray_d, dst, plane, info);
  CubDebugExit(DeviceScan::ExclusiveSum(
      temp_storage_ptr, temp_storage_bytes, info, prefix_sum, num));
  cudaMemcpy(&cnt, prefix_sum + num - 1, sizeof(uint), cudaMemcpyDeviceToHost);
  compactify_shadow_rays_cuda_kernel<<<(num + 1023) / 1024, 1024>>>(
      num, dst, src, map, info, prefix_sum);
  set_shadow_rays_cuda_kernel<<<(cnt + 1023) / 1024, 1024>>>(cnt, src, dst, light);

  return cnt;
}

// Note: this function will be removed
// This kernel will iterate over Nuggets, instead of iterating over rays
__global__ void ray_aabb_kernel(
    const float3* __restrict__ query,     // ray query array
    const float3* __restrict__ ray_d,     // ray direction array
    const float3* __restrict__ ray_inv,   // inverse ray direction array
    const int2* __restrict__ nuggets,     // nugget array (ray-aabb correspondences)
    const float3* __restrict__ points,    // 3d coord array
    const int* __restrict__ info,         // binary array denoting beginning of nugget group
    const int* __restrict__  info_idxes,  // array of active nugget indices
    const float r,                        // radius of aabb
    const bool init,                      // first run?
    float* __restrict__ d,                // distance
    bool* __restrict__ cond,              // true if hit
    int* __restrict__ pidx,               // index of 3d coord array
    const int num_nuggets,                // # of nugget indices
    const int n                           // # of active nugget indices
){
    
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int stride = blockDim.x*gridDim.x;
    if (idx > n) return;

    for (int _i=idx; _i<n; _i+=stride) {
        // Get index of corresponding nugget
        int i = info_idxes[_i];
        
        // Get index of ray
        uint ridx = nuggets[i].x;

        // If this ray is already terminated, continue
        if (!cond[ridx] && !init) continue;

        bool _hit = false;
        
        // Sign bit
        const float3 sgn = ray_sgn(ray_d[ridx]);
        
        int j = 0;
        // In order traversal of the voxels
        do {
            // Get the vc from the nugget
            uint _pidx = nuggets[i].y; // Index of points

            // Center of voxel
            const float3 vc = make_float3(
                fmaf(r, fmaf(2.0, points[_pidx].x, 1.0), -1.0f),
                fmaf(r, fmaf(2.0, points[_pidx].y, 1.0), -1.0f),
                fmaf(r, fmaf(2.0, points[_pidx].z, 1.0), -1.0f));

            float _d = ray_aabb(query[ridx], ray_d[ridx], ray_inv[ridx], sgn, vc, r);

            if (_d != 0.0) {
                _hit = true;
                pidx[ridx] = _pidx;
                cond[ridx] = _hit;
                if (_d > 0.0) {
                    d[ridx] = _d;
                }
            } 
           
            ++i;
            ++j;
            
        } while (i < num_nuggets && info[i] != 1 && _hit == false);

        if (!_hit) {
            // Should only reach here if it misses
            cond[ridx] = false;
            d[ridx] = 100;
        }
        
    }
}

void ray_aabb_cuda(
    const float3* query,     // ray query array
    const float3* ray_d,     // ray direction array
    const float3* ray_inv,   // inverse ray direction array
    const int2*  nuggets,    // nugget array (ray-aabb correspondences)
    const float3* points,    // 3d coord array
    const int* info,         // binary array denoting beginning of nugget group
    const int* info_idxes,   // array of active nugget indices
    const float r,           // radius of aabb
    const bool init,         // first run?
    float* d,                // distance
    bool* cond,              // true if hit
    int* pidx,               // index of 3d coord array
    const int num_nuggets,   // # of nugget indices
    const int n){            // # of active nugget indices

    const int threads = 128;
    const int blocks = (n + threads - 1) / threads;
    ray_aabb_kernel<<<blocks, threads>>>(
        query, ray_d, ray_inv, nuggets, points, info, info_idxes, r, init, d, cond, pidx, num_nuggets, n);
}

}  // namespace kaolin
