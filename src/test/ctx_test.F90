module Base_module
#include "petsc/finclude/petscsnes.h"
  use petscsnes
  implicit none
  private

  type, public :: base_type
    PetscInt :: A  ! junk
    PetscReal :: I ! junk
  contains
    procedure, public :: Print => BasePrint
  end type base_type
contains
subroutine BasePrint(this)
  implicit none
  class(base_type) :: this
  print *
  print *, 'Base printout'
  print *
end subroutine BasePrint
end module Base_module

module Extended_module
#include "petsc/finclude/petscsnes.h"
  use petscsnes
  use Base_module
  implicit none
  private

  type, public, extends(base_type) :: extended_type
    PetscInt :: B  ! junk
    PetscReal :: J ! junk
  contains
    procedure, public :: Print =>  ExtendedPrint
  end type extended_type
contains
subroutine ExtendedPrint(this)
  implicit none
  class(extended_type) :: this
  print *
  print *, 'Extended printout'
  print *
end subroutine ExtendedPrint
end module Extended_module

module Function_module
  implicit none
  public :: TestFunction
  contains
subroutine TestFunction(snes,xx,r,ctx,ierr)
#include "petsc/finclude/petscsnes.h"
  use petscsnes
  use Base_module
  implicit none
  SNES :: snes
  Vec :: xx
  Vec :: r
  class(base_type) :: ctx ! yes, this should be base_type in order to handle all
  PetscErrorCode :: ierr  ! polymorphic extensions
  call ctx%Print()
end subroutine TestFunction
end module Function_module

program test

#include "petsc/finclude/petscsnes.h"
  use petscsnes
  use Base_module
  use Extended_module
  use Function_module

  implicit none

#if 1
interface
  subroutine SNESSetFunction(snes_base,x,TestFunction,base,ierr)
#include "petsc/finclude/petscsnes.h"
  use petscsnes
    use Base_module
    SNES snes_base
    Vec x
    external TestFunction
    class(base_type) :: base
    PetscErrorCode ierr
  end subroutine
end interface
#endif
  PetscMPIInt :: size
  PetscMPIInt :: rank
  
  PetscInt :: ndof
  PetscInt :: my_ndof
  
  SNES :: snes_base, snes_extended
  Vec :: x
  class(base_type), pointer :: base
  class(extended_type), pointer :: extended
  PetscErrorCode :: ierr

  print *, 'Start of Fortran2003 test program'

  nullify(base)
  nullify(extended)
  allocate(base)
  allocate(extended)
  call PetscInitialize(PETSC_NULL_CHARACTER, ierr);CHKERRQ(ierr)
  call MPI_Comm_size(PETSC_COMM_WORLD,size,ierr);CHKERRQ(ierr)
  call MPI_Comm_rank(PETSC_COMM_WORLD,rank,ierr);CHKERRQ(ierr)

  call VecCreate(PETSC_COMM_WORLD,x,ierr);CHKERRQ(ierr)
 
  ! when I use the base class as the context
  print *
  print *, 'the base class will succeed by printing out "Base printout" below'
  call SNESCreate(PETSC_COMM_WORLD,snes_base,ierr);CHKERRQ(ierr)
  call SNESSetFunction(snes_base,x,TestFunction,base,ierr);CHKERRQ(ierr)
  call SNESComputeFunction(snes_base,x,x,ierr);CHKERRQ(ierr)
  call SNESDestroy(snes_base,ierr);CHKERRQ(ierr)

  ! when I use the extended class as the context
  print *, 'the extended class will succeed by printing out "Extended ' // &
           'printout" below'
  call SNESCreate(PETSC_COMM_WORLD,snes_extended,ierr);CHKERRQ(ierr)
  call SNESSetFunction(snes_extended,x,TestFunction,extended,ierr);CHKERRQ(ierr)
  call SNESComputeFunction(snes_extended,x,x,ierr);CHKERRQ(ierr)
  call VecDestroy(x,ierr);CHKERRQ(ierr)
  call SNESDestroy(snes_extended,ierr);CHKERRQ(ierr)
  if (associated(base)) deallocate(base)
  if (associated(extended)) deallocate(extended)
  call PetscFinalize(ierr)

  print *, 'End of Fortran2003 test program'
 
end program test

