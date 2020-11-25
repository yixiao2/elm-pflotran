import h5py
import numpy


def struct_grid_to_ugrid_implicit(out_name, h5, n, d, origin):
  """
  Create a unstructured implicit grid for PFLOTRAN
  out: output file
  h5: true for hdf5 output or false for ascii
  n = [nx, ny nz] with n_i number of element in the i direction
  d = [[dx],[dy],[dz]] with [d_i] the list spacing in the i direction (for uniform, one value only for each d_i
  origin = (x_o,y_o,z_o) coordinate of the origin
  """
  
  if h5:
    out = h5py.File(out_name, mode = 'w')
  else:
    out = open(out_name, 'w')
  
  nx,ny,nz = n
  dx,dy,dz = d
  nxp1 = nx+1; nyp1 = ny+1; nzp1 = nz+1
  
  element_array = numpy.zeros((nx*ny*nz,9),'=i4')
  
  for k in range(nz):
    for j in range(ny):
      for i in range(nx):
        cell_id = i + j*nx + k*nx*ny
        element_array[cell_id,0] = 8
        element_array[cell_id,1] = i + j*nxp1 + k*nxp1*nyp1
        element_array[cell_id,2] = i + 1 + j*nxp1 + k*nxp1*nyp1
        element_array[cell_id,3] = i + 1 + (j+1)*nxp1 + k*nxp1*nyp1
        element_array[cell_id,4] = i + (j+1)*nxp1 + k*nxp1*nyp1
        element_array[cell_id,5] = i + j*nxp1 + (k+1)*nxp1*nyp1
        element_array[cell_id,6] = i + 1 + j*nxp1 + (k+1)*nxp1*nyp1
        element_array[cell_id,7] = i + 1 + (j+1)*nxp1 + (k+1)*nxp1*nyp1
        element_array[cell_id,8] = i + (j+1)*nxp1 + (k+1)*nxp1*nyp1
  
  vertex_array = numpy.zeros((nxp1*nyp1*nzp1,3),'=f8')
  x_origin,y_origin,z_origin = origin
  
  for k in range(nzp1):
    if len(dz) == 1:
      z = k*dz[0] + z_origin
    else:
      if k == 0:
        z = z_origin
      else:
        z += dz[k-1]
    for j in range(nyp1):
      if len(dy) == 1:
        y = j*dy[0] + y_origin
      else:
        if j == 0:
          y = y_origin
        else:
          y += dy[j-1]
      for i in range(nxp1):
        vertex_id = i + j*nxp1 + k*nxp1*nyp1
        if len(dx) == 1:
          x = i*dx[0] + x_origin
        else:
          if i == 0:
            x = x_origin
          else:
            x += dx[i-1]
        vertex_array[vertex_id,0] = x
        vertex_array[vertex_id,1] = y
        vertex_array[vertex_id,2] = z

  if h5:
    h5dset = out.create_dataset('Domain/Cells', data=element_array)
    h5dset = out.create_dataset('Domain/Vertices', data=vertex_array)
  else:
    out.write('%d %d\n' % (nx*ny*nz,nxp1*nyp1*nzp1))
    for k in range(nz):
      for j in range(ny):
        for i in range(nx):
          cell_id = i + j*nx + k*nx*ny
          out.write('H')
          for iv in range(element_array[cell_id,0]):
            out.write(' %d' % (element_array[cell_id,iv+1]+1))
          out.write('\n')
    for i in range(nxp1*nyp1*nzp1):
      out.write('%12.6e %12.6e %12.6e\n' % 
                    (vertex_array[i,0],vertex_array[i,1],vertex_array[i,2]))
  
  out.close()
  
  return True




if __name__ == "__main__":

  nx = 5; ny = 4; nz = 3
  n = (nx,ny,nz)
  
  # for irregular grid spacing, dx,dy,dz must be specified.
  dx = [10.,11.,12.,13.,14.]
  dy = [13.,12.,11.,10.]
  dz = [15.,20.,25.]
  # for uniform grid spacing, specify one value in each direction
  #dx = [1.]
  #dy = [1.]
  #dz = [1.]
  # note that you can mix and match irregular spacing along the different axes
  d = [dx,dy,dz]
  
  x = 0.; y = 0.; z = 0.
  origin = (x,y,z)
  
  h5 = True
  if h5:
    out_name = "mesh_ugi.h5"
  else:
    out_name = "mesh.ugi"
  
  struct_grid_to_ugrid_implicit(out_name, h5, n, d, origin)
  

