module PMC_Geomechanics_class

#include "petsc/finclude/petscsys.h"
  use petscsys
  use PMC_Base_class
  use Realization_Subsurface_class
  use Geomechanics_Realization_class
  use PFLOTRAN_Constants_module

  implicit none


  private

  type, public, extends(pmc_base_type) :: pmc_geomechanics_type
    class(realization_subsurface_type), pointer :: subsurf_realization
    class(realization_geomech_type), pointer :: geomech_realization
  contains
    procedure, public :: Init => PMCGeomechanicsInit
    procedure, public :: SetupSolvers => PMCGeomechanicsSetupSolvers
    procedure, public :: RunToTime => PMCGeomechanicsRunToTime
    procedure, public :: GetAuxData => PMCGeomechanicsGetAuxData
    procedure, public :: SetAuxData => PMCGeomechanicsSetAuxData
    procedure, public :: Destroy => PMCGeomechanicsDestroy
  end type pmc_geomechanics_type

  public :: PMCGeomechanicsCreate

contains

! ************************************************************************** !

function PMCGeomechanicsCreate()
  !
  ! This routine allocates and initializes a new object.
  !
  ! Author: Gautam Bisht, LBNL
  ! Date: 01/01/14
  !

  implicit none

  class(pmc_geomechanics_type), pointer :: PMCGeomechanicsCreate

  class(pmc_geomechanics_type), pointer :: pmc

#ifdef DEBUG
  print *, 'PMCGeomechanicsCreate%Create()'
#endif

  allocate(pmc)
  call pmc%Init()

  PMCGeomechanicsCreate => pmc

end function PMCGeomechanicsCreate

! ************************************************************************** !

subroutine PMCGeomechanicsInit(this)
  !
  ! This routine initializes a new process model coupler object.
  !
  ! Author: Gautam Bisht, LBNL
  ! Date: 01/01/14
  !

  implicit none

  class(pmc_geomechanics_type) :: this

#ifdef DEBUG
  print *, 'PMCGeomechanics%Init()'
#endif

  call PMCBaseInit(this)
  nullify(this%subsurf_realization)
  nullify(this%geomech_realization)

end subroutine PMCGeomechanicsInit

! ************************************************************************** !

subroutine PMCGeomechanicsSetupSolvers(this)
  !
  ! Author: Glenn Hammond
  ! Date: 03/18/13
  !
#include "petsc/finclude/petscsnes.h"
  use petscsnes
  use Convergence_module
  use Geomechanics_Discretization_module
  use Timestepper_Base_class
  use Timestepper_Steady_class
  use PM_Base_class
  use PM_Base_Pointer_module
  use Option_module
  use Solver_module

  implicit none

  class(pmc_geomechanics_type) :: this

  class(realization_geomech_type), pointer :: geomech_realization
  class(geomech_discretization_type), pointer :: geomech_discretization
  class(timestepper_steady_type), pointer :: ts_steady
  type(solver_type), pointer :: solver
  type(option_type), pointer :: option
  SNESLineSearch :: linesearch
  character(len=MAXSTRINGLENGTH) :: string
  PetscErrorCode :: ierr

#ifdef DEBUG
  call PrintMsg(this%option,'PMCGeomechanicsSetupSolvers')
#endif

  option => this%option
  geomech_realization => this%geomech_realization
  geomech_discretization => geomech_realization%geomech_discretization
  select type(ts => this%timestepper)
    class is (timestepper_steady_type)
      ts_steady => ts
      solver => ts%solver
  end select

  call PrintMsg(option,"  Beginning setup of GEOMECH SNES ")

  if (solver%M_mat_type == MATAIJ) then
    option%io_buffer = 'AIJ matrix not supported for geomechanics.'
    call PrintErrMsg(option)
  endif

  call SolverCreateSNES(solver,option%mycomm,'geomech_',option)

  if (solver%snes_type /= SNESNEWTONLS) then
    option%io_buffer = 'Geomechanics only supports the LineSearch SNES_TYPE.'
    call PrintErrMsg(option)
  endif

  if (Uninitialized(solver%Mpre_mat_type) .and. &
      Uninitialized(solver%M_mat_type)) then
    ! Matrix types not specified, so set to default.
    solver%Mpre_mat_type = MATBAIJ
    solver%M_mat_type = solver%Mpre_mat_type
  else if (Uninitialized(solver%Mpre_mat_type)) then
    if (solver%M_mat_type == MATMFFD) then
      solver%Mpre_mat_type = MATBAIJ
    else
      solver%Mpre_mat_type = solver%M_mat_type
    endif
  else if (Uninitialized(solver%M_mat_type)) then
    solver%M_mat_type = solver%Mpre_mat_type
  endif

  call GeomechDiscretizationCreateMatrix(geomech_realization% &
                                         geomech_discretization,NGEODOF, &
                                         solver%Mpre_mat_type, &
                                         solver%Mpre,option)

  solver%M = solver%Mpre
  call MatSetOptionsPrefix(solver%Mpre,"geomech_",ierr);CHKERRQ(ierr)

  ! by default turn off line search
  call SNESGetLineSearch(solver%snes,linesearch,ierr);CHKERRQ(ierr)
  call SNESLineSearchSetType(linesearch,SNESLINESEARCHBASIC, &
                             ierr);CHKERRQ(ierr)


  ! Have PETSc do a SNES_View() at the end of each solve if verbosity > 0.
  if (option%verbosity >= 1) then
    string = '-geomech_snes_view'
    call PetscOptionsInsertString(PETSC_NULL_OPTIONS,string, &
                                  ierr);CHKERRQ(ierr)
  endif

  option%io_buffer = 'Solver: ' // trim(solver%ksp_type)
  call PrintMsg(option)
  option%io_buffer = 'Preconditioner: ' // trim(solver%pc_type)
  call PrintMsg(option)

  call SNESSetConvergenceTest(solver%snes,PMCheckConvergencePtr,this%pm_ptr, &
                              PETSC_NULL_FUNCTION,ierr);CHKERRQ(ierr)
  call SNESSetFunction(solver%snes,this%pm_ptr%pm%residual_vec,PMResidualPtr, &
                       this%pm_ptr,ierr);CHKERRQ(ierr)
  call SNESSetJacobian(solver%snes,solver%M,solver%Mpre,PMJacobianPtr, &
                       this%pm_ptr,ierr);CHKERRQ(ierr)

  call SolverSetSNESOptions(solver,option)

  call PrintMsg(option,"  Finished setting up GEOMECH SNES ")


end subroutine PMCGeomechanicsSetupSolvers

! ************************************************************************** !

recursive subroutine PMCGeomechanicsRunToTime(this,sync_time,stop_flag)
  !
  ! This routine runs the geomechanics simulation.
  !
  ! Author: Gautam Bisht, LBNL
  ! Date: 01/01/14
  !

  use Timestepper_Base_class
  use Option_module
  use PM_Base_class
  use Output_Geomechanics_module

  implicit none

  class(pmc_geomechanics_type), target :: this
  PetscReal :: sync_time
  PetscInt :: stop_flag
  PetscInt :: local_stop_flag
  PetscBool :: sync_flag
  PetscBool :: snapshot_plot_flag
  PetscBool :: observation_plot_flag
  PetscBool :: massbal_plot_flag
  PetscBool :: checkpoint_flag
  PetscBool :: peer_already_run_to_time

  class(pm_base_type), pointer :: cur_pm

  if (stop_flag == TS_STOP_FAILURE) return

  call this%PrintHeader()
  this%option%io_buffer = trim(this%name) // ':' // trim(this%pm_list%name)
  call PrintVerboseMsg(this%option)

  ! Get data of other process-model
  call this%GetAuxData()

  local_stop_flag = 0

  call SetOutputFlags(this)
  sync_flag = PETSC_FALSE
  snapshot_plot_flag = PETSC_FALSE
  observation_plot_flag = PETSC_FALSE
  massbal_plot_flag = PETSC_FALSE

  call this%timestepper%SetTargetTime(sync_time,this%option,local_stop_flag, &
                                      sync_flag, &
                                      snapshot_plot_flag, &
                                      observation_plot_flag, &
                                      massbal_plot_flag,checkpoint_flag)
  call this%timestepper%StepDT(this%pm_list,local_stop_flag)

  ! Check if it is initial solve
  if (this%timestepper%steps == 1) then
    this%option%geomech_initial = PETSC_TRUE
  endif

  ! Have to loop over all process models coupled in this object and update
  ! the time step size.  Still need code to force all process models to
  ! use the same time step size if tightly or iteratively coupled.
  cur_pm => this%pm_list
  do
    if (.not.associated(cur_pm)) exit
    ! have to update option%time for conditions
    this%option%time = this%timestepper%target_time
    call cur_pm%UpdateSolution()
    ! Geomechanics PM does not have an associate time
    !call this%timestepper%UpdateDT(cur_pm)
    cur_pm => cur_pm%next
  enddo

  ! Run underlying process model couplers
  if (associated(this%child)) then
    ! Set data needed by process-model
    call this%SetAuxData()
    call this%child%RunToTime(this%timestepper%target_time,local_stop_flag)
    call this%GetAuxData()
  endif

  peer_already_run_to_time = PETSC_FALSE
  if (sync_flag .and. associated(this%peer)) then
    ! synchronize peers
    call this%SetAuxData()
    ! Run neighboring process model couplers
    call this%peer%RunToTime(this%timestepper%target_time, &
                             local_stop_flag)
    peer_already_run_to_time = PETSC_TRUE
    call this%GetAuxData()
  endif

  if (this%timestepper%time_step_cut_flag) then
    snapshot_plot_flag = PETSC_FALSE
  endif
  ! however, if we are using the modulus of the output_option%imod, we may
  ! still print
  if (mod(this%timestepper%steps,this%pm_list% &
          output_option%periodic_snap_output_ts_imod) == 0) then
    snapshot_plot_flag = PETSC_TRUE
  endif
  if (mod(this%timestepper%steps,this%pm_list%output_option% &
          periodic_obs_output_ts_imod) == 0) then
    observation_plot_flag = PETSC_TRUE
  endif
  if (mod(this%timestepper%steps,this%pm_list%output_option% &
          periodic_msbl_output_ts_imod) == 0) then
    massbal_plot_flag = PETSC_TRUE
  endif

  call OutputGeomechanics(this%geomech_realization,snapshot_plot_flag, &
                          observation_plot_flag,massbal_plot_flag)
  ! Set data needed by process-model
  call this%SetAuxData()

  ! Run neighboring process model couplers
  if (associated(this%peer) .and. .not.peer_already_run_to_time) then
    call this%SetAuxData()
    call this%peer%RunToTime(sync_time,local_stop_flag)
    call this%GetAuxData()
  endif

  stop_flag = max(stop_flag,local_stop_flag)

end subroutine PMCGeomechanicsRunToTime

! ************************************************************************** !

subroutine PMCGeomechanicsSetAuxData(this)
  !
  ! This routine updates data in simulation_aux that is required by other
  ! process models.
  !
  ! Author: Gautam Bisht, LBNL
  ! Date: 01/01/14
  !

#include "petsc/finclude/petscvec.h"
  use petscvec
  use Option_module
  use Grid_module
  use Geomechanics_Subsurface_Properties_module

  implicit none

  class(pmc_geomechanics_type) :: this

  type(grid_type), pointer :: grid
  PetscInt :: local_id
  PetscScalar, pointer :: por0_p(:)
  PetscScalar, pointer :: por_p(:)
  PetscScalar, pointer :: perm0_p(:)
  PetscScalar, pointer :: perm_p(:)
  PetscScalar, pointer :: strain_p(:)
  PetscScalar, pointer :: stress_p(:)
  PetscScalar, pointer :: press_p(:)
  PetscReal :: local_stress(6), local_strain(6), local_pressure
  PetscErrorCode :: ierr
  PetscReal :: por_new
  PetscReal :: perm_new
  PetscInt :: i
  Vec :: geomech_vec
  Vec :: subsurf_vec

#if GEOMECH_DEBUG
  PetscViewer :: viewer
  print *, 'PMCGeomechSetAuxData'
#endif


  ! If at initialization stage, do nothing
!  if (this%timestepper%steps == 0) return

  select type(pmc => this)
    class is(pmc_geomechanics_type)
      if (this%option%geomech_subsurf_coupling == GEOMECH_TWO_WAY_COUPLED) then

        grid => pmc%subsurf_realization%patch%grid

        ! Find the number of geomech grid nodes for each flow cell
        call VecDuplicate(pmc%geomech_realization%geomech_field%strain, &
                          geomech_vec,ierr);CHKERRQ(ierr)
        call VecSet(geomech_vec,1.d0,ierr);CHKERRQ(ierr)

        call VecDuplicate(pmc%sim_aux%subsurf_strain,subsurf_vec, &
                          ierr);CHKERRQ(ierr)
        call VecSet(subsurf_vec,0.d0,ierr);CHKERRQ(ierr)

        call VecScatterBegin(pmc%sim_aux%geomechanics_to_subsurf,geomech_vec, &
                             subsurf_vec,ADD_VALUES,SCATTER_FORWARD, &
                             ierr);CHKERRQ(ierr)
        call VecScatterEnd(pmc%sim_aux%geomechanics_to_subsurf,geomech_vec, &
                           subsurf_vec,ADD_VALUES,SCATTER_FORWARD, &
                           ierr);CHKERRQ(ierr)


#if GEOMECH_DEBUG
  call PetscViewerASCIIOpen(this%option%mycomm, &
                            'subsurf_vec_adjacency_count.out',viewer, &
                            ierr);CHKERRQ(ierr)
  call VecView(subsurf_vec,viewer,ierr);CHKERRQ(ierr)
  call PetscViewerDestroy(viewer,ierr);CHKERRQ(ierr)
#endif

       ! Save strain dataset in sim_aux%subsurf_strain
        call VecSet(pmc%sim_aux%subsurf_strain,0.d0,ierr);CHKERRQ(ierr)
        call VecScatterBegin(pmc%sim_aux%geomechanics_to_subsurf, &
                             pmc%geomech_realization%geomech_field%strain, &
                             pmc%sim_aux%subsurf_strain,ADD_VALUES, &
                             SCATTER_FORWARD,ierr);CHKERRQ(ierr)
        call VecScatterEnd(pmc%sim_aux%geomechanics_to_subsurf, &
                           pmc%geomech_realization%geomech_field%strain, &
                           pmc%sim_aux%subsurf_strain,ADD_VALUES, &
                           SCATTER_FORWARD,ierr);CHKERRQ(ierr)

#if GEOMECH_DEBUG
  call PetscViewerASCIIOpen(this%option%mycomm, &
                            'subsurf_strain_vector_before_averaging.out', &
                            viewer,ierr);CHKERRQ(ierr)
  call VecView(pmc%sim_aux%subsurf_strain,viewer,ierr);CHKERRQ(ierr)
  call PetscViewerDestroy(viewer,ierr);CHKERRQ(ierr)
#endif

        ! Save stress dataset in sim_aux%subsurf_stress
        call VecSet(pmc%sim_aux%subsurf_stress,0.d0,ierr);CHKERRQ(ierr)
        call VecScatterBegin(pmc%sim_aux%geomechanics_to_subsurf, &
                             pmc%geomech_realization%geomech_field%stress, &
                             pmc%sim_aux%subsurf_stress,ADD_VALUES, &
                             SCATTER_FORWARD,ierr);CHKERRQ(ierr)
        call VecScatterEnd(pmc%sim_aux%geomechanics_to_subsurf, &
                           pmc%geomech_realization%geomech_field%stress, &
                           pmc%sim_aux%subsurf_stress,ADD_VALUES, &
                           SCATTER_FORWARD,ierr);CHKERRQ(ierr)

#if GEOMECH_DEBUG
  call PetscViewerASCIIOpen(this%option%mycomm, &
                            'subsurf_stress_vector_before_averaging.out', &
                            viewer,ierr);CHKERRQ(ierr)
  call VecView(pmc%sim_aux%subsurf_stress,viewer,ierr);CHKERRQ(ierr)
  call PetscViewerDestroy(viewer,ierr);CHKERRQ(ierr)
#endif

        ! Calculate the average stress and strain
        call VecPointwiseDivide(pmc%sim_aux%subsurf_strain, &
                                pmc%sim_aux%subsurf_strain,subsurf_vec, &
                                ierr);CHKERRQ(ierr)

#if GEOMECH_DEBUG
  call PetscViewerASCIIOpen(this%option%mycomm, &
                            'subsurf_strain_vector_after_averaging.out', &
                            viewer,ierr);CHKERRQ(ierr)
  call VecView(pmc%sim_aux%subsurf_strain,viewer,ierr);CHKERRQ(ierr)
  call PetscViewerDestroy(viewer,ierr);CHKERRQ(ierr)
#endif

        call VecPointwiseDivide(pmc%sim_aux%subsurf_stress, &
                                pmc%sim_aux%subsurf_stress,subsurf_vec, &
                                ierr);CHKERRQ(ierr)

#if GEOMECH_DEBUG
  call PetscViewerASCIIOpen(this%option%mycomm, &
                            'subsurf_stress_vector_after_averaging.out', &
                            viewer,ierr);CHKERRQ(ierr)
  call VecView(pmc%sim_aux%subsurf_stress,viewer,ierr);CHKERRQ(ierr)
  call PetscViewerDestroy(viewer,ierr);CHKERRQ(ierr)
#endif


        ! Update porosity dataset in sim_aux%subsurf_por
        call VecGetArrayF90(pmc%sim_aux%subsurf_por0,por0_p, &
                            ierr);CHKERRQ(ierr)
        call VecGetArrayF90(pmc%sim_aux%subsurf_por,por_p,ierr);CHKERRQ(ierr)
        ! Perm
        call VecGetArrayF90(pmc%sim_aux%subsurf_perm0,perm0_p, &
                            ierr);CHKERRQ(ierr)
        call VecGetArrayF90(pmc%sim_aux%subsurf_perm,perm_p, &
                            ierr);CHKERRQ(ierr)
        ! Strain
        call VecGetArrayF90(pmc%sim_aux%subsurf_strain,strain_p, &
                            ierr);CHKERRQ(ierr)
        ! Stress
        call VecGetArrayF90(pmc%sim_aux%subsurf_stress,stress_p, &
                            ierr);CHKERRQ(ierr)
        ! Flow
        call VecGetArrayF90(pmc%subsurf_realization%field%flow_xx,press_p, &
                            ierr);CHKERRQ(ierr)

        do local_id = 1, grid%nlmax
          do i = 1, SIX_INTEGER
            local_stress(i) = stress_p((local_id - 1)*SIX_INTEGER + i)
            local_strain(i) = strain_p((local_id - 1)*SIX_INTEGER + i)
          enddo
            local_pressure = press_p(local_id)
          ! Update porosity based on stress/strain
          call GeomechanicsSubsurfacePropsPoroEvaluate( &
                 grid, &
                 pmc%subsurf_realization%patch%aux%Material%auxvars(local_id), &
                 por0_p(local_id),local_stress,local_strain,local_pressure, &
                 por_new,this%option)
          por_p(local_id) = por_new
          ! Update permeability based on stress/strain
          call GeomechanicsSubsurfacePropsPermEvaluate( &
                 grid, &
                 pmc%subsurf_realization%patch%aux%Material%auxvars(local_id), &
                 perm0_p(local_id),local_stress,local_strain,local_pressure, &
                 perm_new,this%option)
          perm_p(local_id) = perm_new
        enddo

        call VecRestoreArrayF90(pmc%sim_aux%subsurf_por0,por0_p, &
                                ierr);CHKERRQ(ierr)
        call VecRestoreArrayF90(pmc%sim_aux%subsurf_strain,strain_p, &
                                ierr);CHKERRQ(ierr)
        call VecRestoreArrayF90(pmc%sim_aux%subsurf_por,por_p, &
                                ierr);CHKERRQ(ierr)
        call VecRestoreArrayF90(pmc%sim_aux%subsurf_stress,stress_p, &
                                ierr);CHKERRQ(ierr)
        call VecRestoreArrayF90(pmc%subsurf_realization%field%flow_xx,press_p, &
                                ierr);CHKERRQ(ierr)

        call VecRestoreArrayF90(pmc%sim_aux%subsurf_perm0,perm0_p, &
                                ierr);CHKERRQ(ierr)
        call VecRestoreArrayF90(pmc%sim_aux%subsurf_perm,perm_p, &
                                ierr);CHKERRQ(ierr)

        call VecDestroy(geomech_vec,ierr);CHKERRQ(ierr)
        call VecDestroy(subsurf_vec,ierr);CHKERRQ(ierr)

    endif

  end select

end subroutine PMCGeomechanicsSetAuxData

! ************************************************************************** !

subroutine PMCGeomechanicsGetAuxData(this)
  !
  ! This routine updates data for geomechanics simulation from other process
  ! models.
  !
  ! Author: Gautam Bisht, LBNL
  ! Date: 01/01/14
  !

#include "petsc/finclude/petscvec.h"
  use petscvec
  use Option_module
  use Geomechanics_Discretization_module
  use Geomechanics_Force_module

  implicit none

  class(pmc_geomechanics_type) :: this

  PetscErrorCode :: ierr

#if GEOMECH_DEBUG
print *, 'PMCGeomechanicsGetAuxData'
#endif

  select type(pmc => this)
    class is(pmc_geomechanics_type)

      call VecScatterBegin(pmc%sim_aux%subsurf_to_geomechanics, &
                           pmc%sim_aux%subsurf_pres, &
                           pmc%geomech_realization%geomech_field%press, &
                           INSERT_VALUES,SCATTER_FORWARD,ierr);CHKERRQ(ierr)
      call VecScatterEnd(pmc%sim_aux%subsurf_to_geomechanics, &
                         pmc%sim_aux%subsurf_pres, &
                         pmc%geomech_realization%geomech_field%press, &
                         INSERT_VALUES,SCATTER_FORWARD,ierr);CHKERRQ(ierr)

      call VecScatterBegin(pmc%sim_aux%subsurf_to_geomechanics, &
                           pmc%sim_aux%subsurf_temp, &
                           pmc%geomech_realization%geomech_field%temp, &
                           INSERT_VALUES,SCATTER_FORWARD,ierr);CHKERRQ(ierr)
      call VecScatterEnd(pmc%sim_aux%subsurf_to_geomechanics, &
                         pmc%sim_aux%subsurf_temp, &
                         pmc%geomech_realization%geomech_field%temp, &
                         INSERT_VALUES,SCATTER_FORWARD,ierr);CHKERRQ(ierr)

      call GeomechDiscretizationGlobalToLocal( &
                            pmc%geomech_realization%geomech_discretization, &
                            pmc%geomech_realization%geomech_field%press, &
                            pmc%geomech_realization%geomech_field%press_loc, &
                            ONEDOF)

      call GeomechDiscretizationGlobalToLocal( &
                            pmc%geomech_realization%geomech_discretization, &
                            pmc%geomech_realization%geomech_field%temp, &
                            pmc%geomech_realization%geomech_field%temp_loc, &
                            ONEDOF)

  end select

end subroutine PMCGeomechanicsGetAuxData

! ************************************************************************** !

subroutine PMCGeomechanicsStrip(this)
  !
  ! Deallocates members of PMC Geomechanics.
  !
  ! Author: Satish Karra
  ! Date: 06/01/16

  implicit none

  class(pmc_geomechanics_type) :: this

  call PMCBaseStrip(this)
  ! realizations destroyed elsewhere
  nullify(this%subsurf_realization)
  nullify(this%geomech_realization)

end subroutine PMCGeomechanicsStrip

! ************************************************************************** !

recursive subroutine PMCGeomechanicsDestroy(this)
  !
  ! Author: Satish Karra
  ! Date: 06/01/16
  !
  use Option_module

  implicit none

  class(pmc_geomechanics_type) :: this

#ifdef DEBUG
  call PrintMsg(this%option,'PMCGeomechanics%Destroy()')
#endif

  if (associated(this%child)) then
    call this%child%Destroy()
    ! destroy does not currently destroy; it strips
    deallocate(this%child)
    nullify(this%child)
  endif

  if (associated(this%peer)) then
    call this%peer%Destroy()
    ! destroy does not currently destroy; it strips
    deallocate(this%peer)
    nullify(this%peer)
  endif

  call PMCGeomechanicsStrip(this)

end subroutine PMCGeomechanicsDestroy

end module PMC_Geomechanics_class
