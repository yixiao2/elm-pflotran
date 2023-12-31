module SrcSink_Sandbox_Downreg_class

! Source/sink Sandbox for downregulating source or sink terms to avoid
! overpressurization (too big a pressure, + or -)
! the source is regulated by multiplying it by
!   (1 - x^2)^2
! with
!   x = (pressure - pref - pressure_max - delta/2)/delta
! for pressure in between of x*delta and (x+1)*delta
! the sink is regulated by multiplying it by
!   1 - (1 - x^2)^2
! with
!   x = (pressure - pref - pressure_min - delta/2)/delta
! for pressure in between of x*delta and (x+1)*delta
! for transpiration sink, the physical interpretation can be that the soil water
! extration rate is decreased from q to 0 as pressure decreases from
! pressure_min - delta/2 to pressure_min + delta/2

! extended from srcsink_sandbox_mass_rate
! currently work in RICHARDS mode

#include "petsc/finclude/petscsys.h"
  use petscsys

  use PFLOTRAN_Constants_module
  use SrcSink_Sandbox_Base_class
  use Dataset_Base_class

  implicit none

  private

  type, public, &
    extends(srcsink_sandbox_base_type) :: srcsink_sandbox_downreg_type
    PetscReal :: pressure_min       ! Pa
    PetscReal :: pressure_max       ! Pa
    PetscReal :: pressure_delta     ! Pa
    class(dataset_base_type), pointer :: dataset
  contains
    procedure, public :: ReadInput => DownregRead
    procedure, public :: Setup => DownregSetup
    procedure, public :: Update => DownregUpdate
    procedure, public :: Evaluate => DownregSrcSink
    procedure, public :: Destroy => DownregDestroy
  end type srcsink_sandbox_downreg_type

  public :: DownregCreate

contains

! ************************************************************************** !

function DownregCreate()
  !
  ! Allocates mass rate src/sink object.
  !
  ! Author: Guoping Tang
  ! Date: 06/03/14

  implicit none

  class(srcsink_sandbox_downreg_type), pointer :: DownregCreate

  allocate(DownregCreate)
  call SSSandboxBaseInit(DownregCreate)
  DownregCreate%pressure_min = -1.0d9
  DownregCreate%pressure_max = 1.0d9
  DownregCreate%pressure_delta = 1.0d4
  nullify(DownregCreate%dataset)

end function DownregCreate

! ************************************************************************** !

subroutine DownregRead(this,input,option)
  !
  ! Reads input deck for mass rate src/sink parameters
  !
  ! Author: Guoping Tang
  ! Date: 06/03/14

  use Option_module
  use String_module
  use Input_Aux_module
  use Units_module, only : UnitsConvertToInternal
  use Condition_module
  use Dataset_module
  use Dataset_Ascii_class
  use Time_Storage_module

  implicit none

  class(srcsink_sandbox_downreg_type) :: this
  type(input_type), pointer :: input
  type(option_type) :: option
  class(dataset_ascii_type), pointer :: dataset_ascii

  character(len=MAXWORDLENGTH) :: word
  character(len=MAXSTRINGLENGTH) :: string
  character(len=MAXWORDLENGTH) :: units, internal_units
  type(time_storage_type), pointer :: null_time_storage
  PetscBool :: found

  nullify(null_time_storage)

  dataset_ascii => DatasetAsciiCreate()
  call DatasetAsciiInit(dataset_ascii)
  dataset_ascii%array_width = option%nflowdof
  dataset_ascii%data_type = DATASET_REAL
  this%dataset => dataset_ascii
  nullify(dataset_ascii)

  call InputPushBlock(input,option)
  do
    call InputReadPflotranString(input,option)
    if (InputError(input)) exit
    if (InputCheckExit(input,option)) exit

    call InputReadCard(input,option,word)
    call InputErrorMsg(input,option,'keyword', &
                       'SOURCE_SINK_SANDBOX,DOWNREG')
    call StringToUpper(word)

    call SSSandboxBaseSelectCase(this,input,option,word,found)
    if (found) cycle

    select case(trim(word))

      case('RATE')
        internal_units = 'unitless/sec'
        call ConditionReadValues(input,option,word,this%dataset, &
                                 units,internal_units)
      case('POSITIVE_REG_PRESSURE')
        call InputReadDouble(input,option,this%pressure_max)
        call InputErrorMsg(input,option,word,'SOURCE_SINK_SANDBOX,DOWNREG')
        internal_units = 'Pa'
        call InputReadAndConvertUnits(input,this%pressure_max, &
                                      internal_units,'SOURCE_SINK_SANDBOX,&
                                      &DOWNREG,POSITIVE_REG_PRESSURE',option)
      case('NEGATIVE_REG_PRESSURE')
        call InputReadDouble(input,option,this%pressure_min)
        call InputErrorMsg(input,option,word,'SOURCE_SINK_SANDBOX,DOWNREG')
        internal_units = 'Pa'
        call InputReadAndConvertUnits(input,this%pressure_min, &
                                      internal_units,'SOURCE_SINK_SANDBOX,&
                                      &DOWNREG,NEGATIVE_REG_PRESSURE',option)
      case('DELTA_REG_PRESSURE')
        call InputReadDouble(input,option,this%pressure_delta)
        call InputErrorMsg(input,option,word,'SOURCE_SINK_SANDBOX,DOWNREG')
        internal_units = 'Pa'
        call InputReadAndConvertUnits(input,this%pressure_delta, &
                                      internal_units,'SOURCE_SINK_SANDBOX,&
                                      &DOWNREG,DELTA_REG_PRESSURE',option)
        if (this%pressure_delta <= 1.0d-10) then
          option%io_buffer = 'SRCSINK_SANDBOX,DOWNREG,DELTA_REG_PRESSURE' // &
            ': the pressure delta is too close to 0 Pa.'
          call PrintErrMsg(option)
        endif
      case default
        call InputKeywordUnrecognized(input,word, &
                                      'SRCSINK_SANDBOX,DOWNREG',option)
    end select
  enddo
  call InputPopBlock(input,option)

  if (associated(this%dataset%time_storage)) then
    ! for now, forcing to step, which makes sense for src/sinks.
    this%dataset%time_storage%time_interpolation_method = INTERPOLATION_STEP
  endif

  string = 'Down Regulation Dataset'
  call DatasetVerify(this%dataset,null_time_storage,string,option)

end subroutine DownregRead

! ************************************************************************** !

subroutine DownregSetup(this,grid,material_auxvars,option)
  !
  ! Sets up the mass rate src/sink
  !
  ! Author: Guoping Tang
  ! Date: 06/03/14

  use Option_module
  use Grid_module
  use Material_Aux_module, only: material_auxvar_type

  implicit none

  class(srcsink_sandbox_downreg_type) :: this
  type(grid_type) :: grid
  type(material_auxvar_type) :: material_auxvars(:)
  type(option_type) :: option

  call SSSandboxBaseSetup(this,grid,material_auxvars,option)

end subroutine DownregSetup

! ************************************************************************** !

subroutine DownregUpdate(this,option)

  use Option_module
  use Dataset_module

  implicit none

  class(srcsink_sandbox_downreg_type) :: this
  type(option_type) :: option

  call DatasetUpdate(this%dataset,option)

end subroutine DownregUpdate

! ************************************************************************** !

subroutine DownregSrcSink(this,Residual,Jacobian,compute_derivative, &
                           material_auxvar,aux_real,option)
  !
  ! Evaluates src/sink storing residual and/or Jacobian
  !
  ! Author: Guoping Tang
  ! Date: 06/04/14
  ! Glenn suggested to use reference pressure for RICHARDS mode
  ! Gautam suggested to use Nathan's smooth function (6/8/2014)

  use Option_module
  use Reaction_Aux_module
  use Material_Aux_module

  implicit none

  class(srcsink_sandbox_downreg_type) :: this
  type(option_type) :: option
  PetscBool :: compute_derivative
  PetscReal :: Residual(option%nflowdof)
  PetscReal :: Jacobian(option%nflowdof,option%nflowdof)
  type(material_auxvar_type) :: material_auxvar
  PetscReal :: aux_real(:)
  PetscReal :: pressure
  PetscReal :: pressure_lower, pressure_upper, x
  PetscReal :: rate_regulator
  PetscReal :: drate_regulator
  PetscReal :: rate

  PetscInt :: idof

  do idof = 1, option%nflowdof
    if (option%iflowmode == RICHARDS_MODE .and. idof == ONE_INTEGER) then
      ! regulate liquid pressure in Richards mode
      pressure = aux_real(3)
      rate = this%dataset%rarray(1)
      rate = rate / FMWH2O        ! from kg/s to kmol/s (for regression tests)
      ! rate = rate / aux_real(2) ! from m^3/s to kmol/s (later on, we wll assume m^3/s)
      if (rate > 0.0d0) then
        ! source
        pressure_lower = this%pressure_max - this%pressure_delta/2.0d0 &
                                           - option%flow%reference_pressure
        pressure_upper = pressure_lower + this%pressure_delta
        if (pressure <= pressure_lower) then
          rate_regulator = 1.0d0
          drate_regulator = 0.0d0
        elseif (pressure >= pressure_upper) then
          rate_regulator = 0.0d0
          drate_regulator = 0.0d0
        else
          x = (pressure - pressure_lower)/this%pressure_delta
          rate_regulator = (1.0d0 - x * x) * (1.0d0 - x * x)
          drate_regulator = 2.0d0 * (1.0d0 - x * x) * (-2.0d0) * x / &
            this%pressure_delta
        endif
        Residual(idof) = rate * rate_regulator
      else
        ! sink
        pressure_lower = this%pressure_min - this%pressure_delta/2.0d0 &
                                           - option%flow%reference_pressure
        pressure_upper = pressure_lower + this%pressure_delta
        if (pressure <= pressure_lower) then
          rate_regulator = 0.0d0
          drate_regulator = 0.0d0
        elseif (pressure >= pressure_upper) then
          rate_regulator = 1.0d0
          drate_regulator = 0.0d0
        else
          x = (pressure - pressure_lower)/this%pressure_delta
          rate_regulator = 1.0d0 - (1.0d0 - x * x) * (1.0d0 - x * x)
          drate_regulator = (-2.0d0) * (1.0d0 - x * x) * (-2.0d0) * x / &
            this%pressure_delta
        endif
        Residual(idof) = rate * rate_regulator
      endif
    else
      option%io_buffer = 'srcsink_sandbox_downreg is implemented ' // &
                         'only for RICHARDS mode.'
      call PrintErrMsg(option)
    endif
  enddo

  if (compute_derivative) then

    do idof = 1, option%nflowdof
      if (option%iflowmode == RICHARDS_MODE .and. idof == ONE_INTEGER) then
        ! regulate liquid pressure in Richards mode
        Jacobian(idof,idof) = -1.0d0 * rate * drate_regulator
      else
        option%io_buffer = 'srcsink_sandbox_downreg is implemented ' // &
                           'only for RICHARDS mode.'
        call PrintErrMsg(option)
      endif
    enddo
  endif

end subroutine DownregSrcSink

! ************************************************************************** !

subroutine DownregDestroy(this)
  !
  ! Destroys allocatable or pointer objects created in this module
  !
  ! Author: Guoping Tang
  ! Date: 06/04/14

  use Dataset_module
  use Dataset_Ascii_class

  implicit none

  class(srcsink_sandbox_downreg_type) :: this
  class(dataset_ascii_type), pointer :: dataset_ascii

  dataset_ascii => DatasetAsciiCast(this%dataset)
  call DatasetAsciiDestroy(dataset_ascii)

  call SSSandboxBaseDestroy(this)

end subroutine DownregDestroy

end module SrcSink_Sandbox_Downreg_class
