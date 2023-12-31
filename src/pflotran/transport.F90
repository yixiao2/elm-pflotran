module Transport_module

#include "petsc/finclude/petscsys.h"
  use petscsys
  use Reactive_Transport_Aux_module
  use Global_Aux_module
  use Material_Aux_module
  use Matrix_Block_Aux_module

  use PFLOTRAN_Constants_module

  implicit none

  private

  public :: TDispersion, &
            TDispersionBC, &
            TFlux, &
            TFluxDerivative, &
            TFluxCoef, &
            TFluxCoefBC, &
            TSrcSinkCoef, &
            TFluxTVD

  ! this interface is required for the pointer to procedure employed
  ! for flux limiters below
  interface
    function TFluxLimiterDummy(d)
      PetscReal :: d
      PetscReal :: TFluxLimiterDummy
    end function TFluxLimiterDummy
  end interface

  public :: TFluxLimiterDummy, &
            TFluxLimiter, &
            TFluxLimitUpwind, &
            TFluxLimitMinmod, &
            TFluxLimitMC, &
            TFluxLimitSuperBee, &
            TFluxLimitVanLeer

  PetscInt, parameter, public :: TVD_LIMITER_UPWIND = 1
  PetscInt, parameter, public :: TVD_LIMITER_MC = 2
  PetscInt, parameter, public :: TVD_LIMITER_MINMOD = 3
  PetscInt, parameter, public :: TVD_LIMITER_SUPERBEE = 4
  PetscInt, parameter, public :: TVD_LIMITER_VAN_LEER = 5

contains

! ************************************************************************** !

subroutine TDispersion(global_auxvar_up,material_auxvar_up, &
                      cell_centered_velocity_up,dispersivity_up,epsilon_up, &
                      global_auxvar_dn,material_auxvar_dn, &
                      cell_centered_velocity_dn,dispersivity_dn,epsilon_dn, &
                      dist,rt_parameter,option,qdarcy, &
                      harmonic_tran_coefs_over_dist)
  !
  ! Computes a single coefficient representing:
  !   (saturation * porosity *
  !   (mechanical_dispersion + tortuosity * molecular_diffusion) /
  !    distance [between cell centers] through a harmonic average
  !
  ! Author: Glenn Hammond
  ! Date: 08/31/16
  !

  use Option_module
  use Connection_module

  implicit none

  type(option_type) :: option
  type(global_auxvar_type) :: global_auxvar_up, global_auxvar_dn
  type(material_auxvar_type) :: material_auxvar_up, material_auxvar_dn
  PetscReal :: dispersivity_up(3), dispersivity_dn(3)
  PetscReal :: cell_centered_velocity_up(3,2), &
               cell_centered_velocity_dn(3,2)
  PetscReal :: epsilon_up, epsilon_dn
  PetscReal :: dist(-1:3)
  PetscReal :: qdarcy(*)
  type(reactive_transport_param_type) :: rt_parameter
  PetscReal :: harmonic_tran_coefs_over_dist(rt_parameter%naqcomp, &
                                             rt_parameter%nphase)

  PetscInt :: iphase, nphase
  PetscReal :: abs_dist(3)
  PetscReal :: dist_up, dist_dn
  PetscReal :: sat_up, sat_dn
  PetscReal :: velocity_dn(3), velocity_up(3)
  PetscReal :: distance_gravity, upwind_weight ! both are dummy variables
  PetscReal :: q
  PetscReal :: Dxx_up, Dyy_up, Dzz_up
  PetscReal :: Dxx_dn, Dyy_dn, Dzz_dn
  PetscInt, parameter :: LONGITUDINAL = 1
  PetscInt, parameter :: TRANSVERSE_HORIZONTAL = 2
  PetscInt, parameter :: TRANSVERSE_VERTICAL = 3
  PetscReal :: mechanical_dispersion_up
  PetscReal :: mechanical_dispersion_dn
  PetscReal :: molecular_diffusion_up(rt_parameter%naqcomp)
  PetscReal :: molecular_diffusion_dn(rt_parameter%naqcomp)
  PetscReal :: hydrodynamic_dispersion_up(rt_parameter%naqcomp)
  PetscReal :: hydrodynamic_dispersion_dn(rt_parameter%naqcomp)
  PetscReal :: t_ref_inv
  PetscReal :: v_up, v_dn
  PetscReal :: vi2_over_v_up, vj2_over_v_up, vk2_over_v_up
  PetscReal :: vi2_over_v_dn, vj2_over_v_dn, vk2_over_v_dn

  PetscReal, parameter :: s_pow = 7.d0/3.d0
  PetscReal, parameter :: por_pow = 1.d0/3.d0

  nphase = rt_parameter%nphase

  abs_dist(:) = dabs(dist(1:3))
  harmonic_tran_coefs_over_dist(:,:) = 0.d0

  call ConnectionCalculateDistances(dist,option%gravity,dist_up, &
                                    dist_dn,distance_gravity, &
                                    upwind_weight)
  do iphase = 1, nphase
    sat_up = global_auxvar_up%sat(iphase)
    sat_dn = global_auxvar_dn%sat(iphase)
    ! skip phase if it does not exist on either side of the connection
    if (sat_up < rt_min_saturation .or. sat_dn < rt_min_saturation) cycle
    if (rt_parameter%temperature_dependent_diffusion) then
      select case(iphase)
        case(LIQUID_PHASE)
          t_ref_inv = 1.d0/298.15d0 ! 1. / (25. + 273.15)
          molecular_diffusion_up(:) = &
            rt_parameter%diffusion_coefficient(:,iphase) * &
            exp(rt_parameter%diffusion_activation_energy(:,iphase) / &
                IDEAL_GAS_CONSTANT* &
                (t_ref_inv - 1.d0/(global_auxvar_up%temp + 273.15d0)))
          molecular_diffusion_dn(:) = &
            rt_parameter%diffusion_coefficient(:,iphase) * &
            exp(rt_parameter%diffusion_activation_energy(:,iphase) / &
                IDEAL_GAS_CONSTANT* &
                (t_ref_inv - 1.d0/(global_auxvar_dn%temp + 273.15d0)))
        case(GAS_PHASE)
          ! if gas phase exists, gas pressure %pres(GAS_PHASE) should be total
          ! pressure
          molecular_diffusion_up(:) = &
            rt_parameter%diffusion_coefficient(:,iphase) * &
            ((((global_auxvar_up%temp+273.15d0)/273.15d0)**1.8d0) * &
             (101325.d0/global_auxvar_up%pres(GAS_PHASE)))
          molecular_diffusion_dn(:) = &
            rt_parameter%diffusion_coefficient(:,iphase) * &
            ((((global_auxvar_dn%temp+273.15d0)/273.15d0)**1.8d0) * &
             (101325.d0/global_auxvar_dn%pres(GAS_PHASE)))
      end select
    else
      molecular_diffusion_up(:) = &
            rt_parameter%diffusion_coefficient(:,iphase)
      molecular_diffusion_dn(:) = &
            rt_parameter%diffusion_coefficient(:,iphase)
    endif
    if (rt_parameter%millington_quirk_tortuosity) then
      molecular_diffusion_up(:) = &
            molecular_diffusion_up(:) * &
            sat_up**s_pow * &
            material_auxvar_up%porosity**por_pow
      molecular_diffusion_dn(:) = &
            molecular_diffusion_dn(:) * &
            sat_dn**s_pow * &
            material_auxvar_dn%porosity**por_pow
    endif
    q = qdarcy(iphase)
    if (rt_parameter%calculate_transverse_dispersion) then
      velocity_up = q*abs_dist(1:3) + (1.d0-abs_dist(1:3))* &
                    cell_centered_velocity_up(:,iphase)
      velocity_dn = q*abs_dist(1:3) + (1.d0-abs_dist(1:3))* &
                    cell_centered_velocity_dn(:,iphase)
      v_up = sqrt(dot_product(velocity_up,velocity_up))
      vi2_over_v_up = velocity_up(X_DIRECTION)**2/v_up
      vj2_over_v_up = velocity_up(Y_DIRECTION)**2/v_up
      vk2_over_v_up = velocity_up(Z_DIRECTION)**2/v_up
      v_dn = sqrt(dot_product(velocity_dn,velocity_dn))
      vi2_over_v_dn = velocity_dn(X_DIRECTION)**2/v_dn
      vj2_over_v_dn = velocity_dn(Y_DIRECTION)**2/v_dn
      vk2_over_v_dn = velocity_dn(Z_DIRECTION)**2/v_dn
      Dxx_up = dispersivity_up(LONGITUDINAL)*vi2_over_v_up + &
               dispersivity_up(TRANSVERSE_HORIZONTAL)*vj2_over_v_up + &
               dispersivity_up(TRANSVERSE_VERTICAL)*vk2_over_v_up

      Dxx_dn = dispersivity_dn(LONGITUDINAL)*vi2_over_v_dn + &
               dispersivity_dn(TRANSVERSE_HORIZONTAL)*vj2_over_v_dn + &
               dispersivity_dn(TRANSVERSE_VERTICAL)*vk2_over_v_dn

      Dyy_up = dispersivity_up(TRANSVERSE_HORIZONTAL)*vi2_over_v_up + &
               dispersivity_up(LONGITUDINAL)*vj2_over_v_up + &
               dispersivity_up(TRANSVERSE_VERTICAL)*vk2_over_v_up

      Dyy_dn = dispersivity_dn(TRANSVERSE_HORIZONTAL)*vi2_over_v_dn + &
               dispersivity_dn(LONGITUDINAL)*vj2_over_v_dn + &
               dispersivity_dn(TRANSVERSE_VERTICAL)*vk2_over_v_dn

      Dzz_up = dispersivity_up(TRANSVERSE_VERTICAL)*vi2_over_v_up + &
               dispersivity_up(TRANSVERSE_VERTICAL)*vj2_over_v_up + &
               dispersivity_up(LONGITUDINAL)*vk2_over_v_up

      Dzz_dn = dispersivity_dn(TRANSVERSE_VERTICAL)*vi2_over_v_dn + &
               dispersivity_dn(TRANSVERSE_VERTICAL)*vj2_over_v_dn + &
               dispersivity_dn(LONGITUDINAL)*vk2_over_v_dn
      ! dot product on unit direction vector
      mechanical_dispersion_up = &
        max(dist(1)**2*Dxx_up+dist(2)**2*Dyy_up+dist(3)**2*Dzz_up,1.d-40)
      mechanical_dispersion_dn = &
        max(dist(1)**2*Dxx_dn+dist(2)**2*Dyy_dn+dist(3)**2*Dzz_dn,1.d-40)
    else
      mechanical_dispersion_up = dispersivity_up(LONGITUDINAL)*dabs(q)
      mechanical_dispersion_dn = dispersivity_dn(LONGITUDINAL)*dabs(q)
    endif
    ! hydrodynamic dispersion = mechanical disperson + &
    !   saturation * porosity * tortuosity * molecular diffusion
    hydrodynamic_dispersion_up(:) = &
      max(mechanical_dispersion_up + &
          epsilon_up * sat_up * material_auxvar_up%porosity * &
          material_auxvar_up%tortuosity * molecular_diffusion_up(:), &
          1.d-40)
    hydrodynamic_dispersion_dn(:) = &
      max(mechanical_dispersion_dn + &
          epsilon_dn * sat_dn * material_auxvar_dn%porosity * &
          material_auxvar_dn%tortuosity * molecular_diffusion_dn(:), &
          1.d-40)
    ! harmonic average of hydrodynamic dispersion divided by distance
    harmonic_tran_coefs_over_dist(:,iphase) = &
      (hydrodynamic_dispersion_up(:)*hydrodynamic_dispersion_dn(:))/ &
      (hydrodynamic_dispersion_up(:)*dist_dn + &
       hydrodynamic_dispersion_dn(:)*dist_up)
  enddo

end subroutine TDispersion

! ************************************************************************** !

subroutine TDispersionBC(ibndtype, &
                          global_auxvar_up, &
                          global_auxvar_dn,material_auxvar_dn, &
                          cell_centered_velocity_dn,dispersivity_dn,&
                          epsilon_dn,dist_dn, &
                          rt_parameter,option,qdarcy, &
                          tran_coefs_over_dist)
  !
  ! Computes a single coefficient representing:
  !   (saturation * porosity *
  !   (mechanical_dispersion + tortuosity * molecular_diffusion) /
  !    distance [between cell centers]
  !
  ! Author: Glenn Hammond
  ! Date: 08/31/16
  !

  use Option_module
  use Connection_module

  implicit none

  PetscInt :: ibndtype
  type(option_type) :: option
  type(global_auxvar_type) :: global_auxvar_up, global_auxvar_dn
  type(material_auxvar_type) :: material_auxvar_dn
  PetscReal :: dispersivity_dn(3)
  PetscReal :: cell_centered_velocity_dn(3,2)
  PetscReal :: epsilon_dn
  PetscReal :: dist_dn(-1:3)
  PetscReal :: qdarcy(*)
  type(reactive_transport_param_type) :: rt_parameter
  PetscReal :: tran_coefs_over_dist(rt_parameter%naqcomp, &
                                             rt_parameter%nphase)

  PetscInt :: iphase, nphase
  PetscReal :: sat_up, sat_dn
  PetscReal :: abs_dist_dn(3)
  PetscReal :: velocity_dn(3)
  PetscReal :: q
  PetscReal :: Dxx, Dyy, Dzz
  PetscInt, parameter :: LONGITUDINAL = 1
  PetscInt, parameter :: TRANSVERSE_HORIZONTAL = 2
  PetscInt, parameter :: TRANSVERSE_VERTICAL = 3
  PetscReal :: mechanical_dispersion
  PetscReal :: molecular_diffusion(rt_parameter%naqcomp)
  PetscReal :: hydrodynamic_dispersion(rt_parameter%naqcomp)
  PetscReal :: v_dn
  PetscReal :: vi2_over_v_dn, vj2_over_v_dn, vk2_over_v_dn
  PetscReal :: t_ref_inv

  PetscReal, parameter :: s_pow = 7.d0/3.d0
  PetscReal, parameter :: por_pow = 1.d0/3.d0

  nphase = rt_parameter%nphase

  abs_dist_dn(:) = dabs(dist_dn(1:3))
  tran_coefs_over_dist(:,:) = 0.d0

  do iphase = 1, nphase
    ! we use upwind saturation as that is the saturation at the boundary face
    sat_up = global_auxvar_up%sat(iphase)
    sat_dn = global_auxvar_dn%sat(iphase)
    if (sat_up < rt_min_saturation .or. sat_dn < rt_min_saturation) cycle
    if (rt_parameter%temperature_dependent_diffusion) then
      select case(iphase)
        case(LIQUID_PHASE)
          t_ref_inv = 1.d0/298.15d0 ! 1. / (25. + 273.15)
          molecular_diffusion(:) = &
            rt_parameter%diffusion_coefficient(:,iphase) * &
            exp(rt_parameter%diffusion_activation_energy(:,iphase) / &
                IDEAL_GAS_CONSTANT* &
                (t_ref_inv - 1.d0/(global_auxvar_up%temp + 273.15d0)))
        case(GAS_PHASE)
          ! if gas phase exists, gas pressure %pres(GAS_PHASE) should be total
          ! pressure
          molecular_diffusion(:) = &
            rt_parameter%diffusion_coefficient(:,iphase) * &
            ((((global_auxvar_up%temp+273.15d0)/273.15d0)**1.8d0) * &
             (101325.d0/global_auxvar_up%pres(GAS_PHASE)))
      end select
    else
      molecular_diffusion(:) = &
        rt_parameter%diffusion_coefficient(:,iphase)
    endif
    if (rt_parameter%millington_quirk_tortuosity) then
      molecular_diffusion(:) = &
            molecular_diffusion(:) * &
            sat_dn**s_pow * &
            material_auxvar_dn%porosity**por_pow
    endif
    q = qdarcy(iphase)
    if (rt_parameter%calculate_transverse_dispersion) then
      velocity_dn = q*abs_dist_dn(1:3) + (1.d0-abs_dist_dn(1:3))* &
                    cell_centered_velocity_dn(:,iphase)
      v_dn = sqrt(dot_product(velocity_dn,velocity_dn))
      vi2_over_v_dn = velocity_dn(X_DIRECTION)**2/v_dn
      vj2_over_v_dn = velocity_dn(Y_DIRECTION)**2/v_dn
      vk2_over_v_dn = velocity_dn(Z_DIRECTION)**2/v_dn
      Dxx = dispersivity_dn(LONGITUDINAL)*vi2_over_v_dn + &
            dispersivity_dn(TRANSVERSE_HORIZONTAL)*vj2_over_v_dn + &
            dispersivity_dn(TRANSVERSE_VERTICAL)*vk2_over_v_dn

      Dyy = dispersivity_dn(TRANSVERSE_HORIZONTAL)*vi2_over_v_dn + &
            dispersivity_dn(LONGITUDINAL)*vj2_over_v_dn + &
            dispersivity_dn(TRANSVERSE_VERTICAL)*vk2_over_v_dn

      Dzz = dispersivity_dn(TRANSVERSE_VERTICAL)*vi2_over_v_dn + &
            dispersivity_dn(TRANSVERSE_VERTICAL)*vj2_over_v_dn + &
            dispersivity_dn(LONGITUDINAL)*vk2_over_v_dn
      ! dot product on unit direction vector
      mechanical_dispersion = &
        max(dist_dn(1)**2*Dxx+dist_dn(2)**2*Dyy+dist_dn(3)**2*Dzz,1.d-40)
    else
      mechanical_dispersion = dispersivity_dn(LONGITUDINAL)*dabs(q)
    endif

    select case(ibndtype)
      case(DIRICHLET_BC,DIRICHLET_ZERO_GRADIENT_BC)
        ! if outflow, skip
        if (ibndtype == DIRICHLET_ZERO_GRADIENT_BC .and. q < 0.d0) cycle
        ! hydrodynamic dispersion = mechanical disperson + &
        !   saturation * porosity * tortuosity * molecular diffusion
        hydrodynamic_dispersion(:) = &
          max(mechanical_dispersion + &
              ! yes, sat_up due to boundary saturation governing, but
              ! perhaps we could use an average in the future
              epsilon_dn * sat_up * material_auxvar_dn%porosity * &
              material_auxvar_dn%tortuosity * molecular_diffusion(:), &
              1.d-40)
        ! hydrodynamic dispersion divided by distance
        ! units = (m^3 water/m^4 bulk)*(m^2 bulk/sec) = m^3 water/m^2 bulk/sec
        tran_coefs_over_dist(:,iphase) =  &
          hydrodynamic_dispersion(:)/dist_dn(0)
      case(CONCENTRATION_SS,NEUMANN_BC,ZERO_GRADIENT_BC,MEMBRANE_BC)
    end select
  enddo

end subroutine TDispersionBC

! ************************************************************************** !

subroutine TFlux(rt_parameter, &
                 rt_auxvar_up,global_auxvar_up, &
                 rt_auxvar_dn,global_auxvar_dn, &
                 coef_up,coef_dn,option,Flux,Res)
  !
  ! Computes flux term in residual function
  !
  ! Author: Glenn Hammond
  ! Date: 02/15/08
  !

  use Option_module

  implicit none

  type(reactive_transport_param_type) :: rt_parameter
  type(reactive_transport_auxvar_type) :: rt_auxvar_up, rt_auxvar_dn
  type(global_auxvar_type) :: global_auxvar_up, global_auxvar_dn
  type(option_type) :: option
  PetscReal :: coef_up(rt_parameter%naqcomp,rt_parameter%nphase)
  PetscReal :: coef_dn(rt_parameter%naqcomp,rt_parameter%nphase)
  PetscReal :: Res(rt_parameter%ncomp)
  PetscReal :: Flux(rt_parameter%naqcomp,rt_parameter%nphase)

  PetscInt :: iphase
  PetscInt :: ndof

  iphase = 1
  ndof = rt_parameter%naqcomp

  Flux = 0.d0
  Res = 0.d0

  ! units = (L water/sec)*(mol/L) = mol/s
  ! total = mol/L water
  Flux(1:ndof,iphase) = &
    coef_up(1:ndof,iphase)*rt_auxvar_up%total(1:ndof,iphase) + &
    coef_dn(1:ndof,iphase)*rt_auxvar_dn%total(1:ndof,iphase)
  Res(1:ndof) = Flux(1:ndof,iphase)

  if (rt_parameter%ngas > 0) then
    iphase = 2
    Flux(1:ndof,iphase) = Flux(1:ndof,iphase) + &
                  coef_up(1:ndof,iphase)*rt_auxvar_up%total(1:ndof,iphase) + &
                  coef_dn(1:ndof,iphase)*rt_auxvar_dn%total(1:ndof,iphase)
    Res(1:ndof) = Res(1:ndof) + Flux(1:ndof,iphase)
  endif

end subroutine TFlux

! ************************************************************************** !

subroutine TFluxDerivative(rt_parameter, &
                           rt_auxvar_up,global_auxvar_up, &
                           rt_auxvar_dn,global_auxvar_dn, &
                           coef_up,coef_dn,option,J_up,J_dn)
  !
  ! Computes derivatives of flux term in residual function
  !
  ! Author: Glenn Hammond
  ! Date: 02/15/08
  !

  use Option_module

  implicit none

  type(reactive_transport_param_type) :: rt_parameter
  type(option_type) :: option
  type(reactive_transport_auxvar_type) :: rt_auxvar_up, rt_auxvar_dn
  type(global_auxvar_type) :: global_auxvar_up, global_auxvar_dn
  PetscReal :: coef_up(rt_parameter%naqcomp,rt_parameter%nphase)
  PetscReal :: coef_dn(rt_parameter%naqcomp,rt_parameter%nphase)
  PetscReal :: J_up(rt_parameter%ncomp,rt_parameter%ncomp), &
               J_dn(rt_parameter%ncomp,rt_parameter%ncomp)

  PetscInt :: iphase
  PetscInt :: icomp
  PetscInt :: istart
  PetscInt :: iendaq
  PetscInt :: nphase
  PetscInt :: irow

  nphase = rt_parameter%nphase

  ! units = (m^3 water/sec)*(kg water/L water)*(1000L water/m^3 water)
  !       = kg water/sec
  istart = 1
  iendaq = rt_parameter%naqcomp
  J_up = 0.d0
  J_dn = 0.d0
  do iphase = 1, nphase
    if (associated(rt_auxvar_dn%aqueous%dtotal)) then
      do irow = istart, iendaq
        J_up(irow,istart:iendaq) = &
          J_up(irow,istart:iendaq) + &
          rt_auxvar_up%aqueous%dtotal(irow,:,iphase)* &
          coef_up(irow,iphase)
        J_dn(irow,istart:iendaq) = &
          J_dn(irow,istart:iendaq) + &
          rt_auxvar_dn%aqueous%dtotal(irow,:,iphase)* &
          coef_dn(irow,iphase)
      enddo
    else
      do icomp = istart, iendaq
        J_up(icomp,icomp) = J_up(icomp,icomp) + coef_up(icomp,iphase)* &
                            global_auxvar_up%den_kg(iphase)*1.d-3
        J_dn(icomp,icomp) = J_dn(icomp,icomp) + coef_dn(icomp,iphase)* &
                            global_auxvar_dn%den_kg(iphase)*1.d-3
      enddo
    endif
  enddo

end subroutine TFluxDerivative

! ************************************************************************** !

subroutine TFluxCoef(rt_parameter, &
                     global_auxvar_up,global_auxvar_dn, &
                     option,area,velocity, &
                     tran_coefs_over_dist, &
                     fraction_upwind,check_upwind_saturation,T_up,T_dn)
  !
  ! Computes flux coefficients for transport matrix
  !
  ! Author: Glenn Hammond
  ! Date: 02/22/10
  !

  use Option_module

  implicit none

  type(reactive_transport_param_type) :: rt_parameter
  type(global_auxvar_type) :: global_auxvar_up, global_auxvar_dn
  type(option_type) :: option
  PetscReal :: area
  PetscReal :: velocity(*)
  ! this is the harmonic mean of saturation * porosity * (mechanical
  !   dispersion + tortuosity * molecular_diffusion) / distance
  PetscReal :: tran_coefs_over_dist(rt_parameter%naqcomp, &
                                    rt_parameter%nphase)
  PetscReal :: fraction_upwind
  PetscBool :: check_upwind_saturation
  PetscReal :: T_up(rt_parameter%naqcomp,rt_parameter%nphase)
  PetscReal :: T_dn(rt_parameter%naqcomp,rt_parameter%nphase)

  PetscInt :: iphase, nphase
  PetscReal :: coef_up(rt_parameter%naqcomp)
  PetscReal :: coef_dn(rt_parameter%naqcomp)
  PetscReal :: q

  nphase = rt_parameter%nphase

  T_up(:,:) = 0.d0
  T_dn(:,:) = 0.d0

  ! as long as gas phase chemistry is a function of aqueous, skip both phases
  if (global_auxvar_dn%sat(LIQUID_PHASE) < rt_min_saturation) then
    return
  else if (check_upwind_saturation) then
    ! for boundary conditions, we can have a zero aqueous saturation upwind
    ! and it does not matter
    if (global_auxvar_up%sat(LIQUID_PHASE) < rt_min_saturation) then
      return
    endif
  endif

  do iphase = 1, nphase
    q = velocity(iphase)

    ! upstream weighting
    ! units = (m^3 water/m^2 bulk/sec)
    if (q > 0.d0) then
      coef_up(:) =  tran_coefs_over_dist(:,iphase)+q
      coef_dn(:) = -tran_coefs_over_dist(:,iphase)
    else
      coef_up(:) =  tran_coefs_over_dist(:,iphase)
      coef_dn(:) = -tran_coefs_over_dist(:,iphase)+q
    endif

    ! units = (m^3 water/m^2 bulk/sec)*(m^2 bulk)*(1000 L water/m^3 water)
    !       = L water/sec
    T_up(:,iphase) = coef_up*area*1000.d0  ! 1000 converts m^3 -> L
    T_dn(:,iphase) = coef_dn*area*1000.d0
  enddo

end subroutine TFluxCoef

! ************************************************************************** !

subroutine TFluxCoefBC(bctype,rt_parameter, &
                       global_auxvar_up,global_auxvar_dn, &
                       option,area,velocity, &
                       tran_coefs_over_dist, &
                       fraction_upwind,T_up,T_dn)
  !
  ! Computes boundary flux coefficients for transport matrix
  !
  ! Author: Glenn Hammond
  ! Date: 10/20/22
  !

  use Option_module

  implicit none

  PetscInt :: bctype
  type(reactive_transport_param_type) :: rt_parameter
  type(global_auxvar_type) :: global_auxvar_up, global_auxvar_dn
  type(option_type) :: option
  PetscReal :: area
  PetscReal :: velocity(*)
  PetscReal :: tran_coefs_over_dist(rt_parameter%naqcomp, &
                                    rt_parameter%nphase)
  PetscReal :: fraction_upwind
  PetscReal :: T_up(rt_parameter%naqcomp,rt_parameter%nphase)
  PetscReal :: T_dn(rt_parameter%naqcomp,rt_parameter%nphase)

  select case(bctype)
    case(MEMBRANE_BC)
      T_up = 0.d0
      T_dn = 0.d0
    case default
      call TFluxCoef(rt_parameter, &
                     global_auxvar_up,global_auxvar_dn, &
                     option,area,velocity, &
                     tran_coefs_over_dist, &
                     fraction_upwind,PETSC_FALSE,T_up,T_dn)
  end select

end subroutine TFluxCoefBC

! ************************************************************************** !

subroutine TSrcSinkCoef(rt_parameter,global_auxvar,qsrc, &
                        tran_src_sink_type,T_in,T_out)
  !
  ! Computes src/sink coefficients for transport matrix
  ! Here qsrc [m^3/sec] provided by flow.
  !
  ! Author: Glenn Hammond
  ! Date: 01/12/11
  !

  use Option_module

  implicit none

  type(reactive_transport_param_type) :: rt_parameter
  type(global_auxvar_type) :: global_auxvar
  PetscReal :: qsrc(2)
  PetscInt :: tran_src_sink_type
  PetscReal :: T_in(2) ! coefficient that scales concentration at cell
  PetscReal :: T_out(2) ! concentration that scales external concentration

  PetscInt :: iphase

  T_in = 0.d0
  T_out = 0.d0

  if (global_auxvar%sat(LIQUID_PHASE) < rt_min_saturation) return

  select case(tran_src_sink_type)
    case(EQUILIBRIUM_SS)
      ! units should be mol/sec
      ! 1.d-3 is a relatively large rate designed to equilibrate
      ! the aqueous concentration with the concentrations specified at
      ! the src/sink
      T_in = 1.d-3 ! units L water/sec
      T_out = -1.d0*T_in
    case(MASS_RATE_SS)
      ! in this case, rt_auxvar_bc%total actually holds the mass rate
      T_in = 0.d0
      T_out = -1.d0
    case(MEMBRANE_BC)
      T_in = 0.d0
      T_out = 0.d0
    case default
      ! qsrc always in m^3/sec
      do iphase = 1, rt_parameter%nphase
        if (qsrc(iphase) > 0.d0) then ! injection
          T_in(iphase) = 0.d0
          T_out(iphase) = -1.d0*qsrc(iphase)*1000.d0 ! m^3/sec * 1000 L/m^3 -> L/s
        else
          T_out(iphase) = 0.d0
          T_in(iphase) = -1.d0*qsrc(iphase)*1000.d0 ! m^3/sec * 1000 L/m^3 -> L/s
        endif
      enddo
  end select

  ! Units of Tin & Tout should be L/s.  When multiplied by Total (M) you get
  ! moles/sec, the units of the residual.  To get the units of the Jacobian
  ! kg/sec, one must either scale by dtotal or den/1000. (kg/L).

end subroutine TSrcSinkCoef

! ************************************************************************** !

subroutine TFluxTVD(rt_parameter,velocity,area,dist, &
                    total_up2,rt_auxvar_up, &
                    rt_auxvar_dn,total_dn2, &
                    TFluxLimitPtr, &
                    option,flux)
  !
  ! Computes TVD flux term
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  use Option_module

  implicit none

  type(reactive_transport_param_type) :: rt_parameter
  PetscReal :: velocity(:), area
  type(reactive_transport_auxvar_type) :: rt_auxvar_up, rt_auxvar_dn
  PetscReal, pointer :: total_up2(:,:), total_dn2(:,:)
  type(option_type) :: option
  PetscReal :: flux(rt_parameter%ncomp)
  procedure (TFluxLimiterDummy), pointer :: TFluxLimitPtr
  PetscReal :: dist(-1:3)    ! list of distance vectors, size(-1:3,num_connections) where
                            !   -1 = fraction upwind
                            !   0 = magnitude of distance
                            !   1-3 = components of unit vector

  PetscInt :: iphase
  PetscInt :: idof, ndof
  PetscReal :: dc, theta, correction, nu, velocity_area

  ndof = rt_parameter%naqcomp

  flux = 0.d0

  ! flux should be in mol/sec

  do iphase = 1, rt_parameter%nphase
    nu = velocity(iphase)*option%tran_dt/dist(0)
    ! L/sec = m/sec * m^2 * 1000 [L/m^3]
    velocity_area = velocity(iphase)*area*1000.d0
    if (velocity_area >= 0.d0) then
      ! mol/sec = L/sec * mol/L
      flux = velocity_area*rt_auxvar_up%total(1:rt_parameter%naqcomp,iphase)
      if (associated(total_up2)) then
        do idof = 1, ndof
          dc = rt_auxvar_dn%total(idof,iphase) - &
               rt_auxvar_up%total(idof,iphase)
          if (dabs(dc) < 1.d-20) then
            theta = 1.d0
          else
            theta = (rt_auxvar_up%total(idof,iphase) - &
                    total_up2(idof,iphase)) / &
                    dc
          endif
          ! mol/sec = L/sec * mol/L
          correction = 0.5d0*velocity_area*(1.d0-nu)* &
                       TFluxLimitPtr(theta)* &
                       dc
          flux(idof) = flux(idof) + correction
        enddo
      endif
    else
      flux = velocity_area*rt_auxvar_dn%total(1:rt_parameter%naqcomp,iphase)
      if (associated(total_dn2)) then
        do idof = 1, ndof
          dc = rt_auxvar_dn%total(idof,iphase) - &
               rt_auxvar_up%total(idof,iphase)
          if (dabs(dc) < 1.d-20) then
            theta = 1.d0
          else
            theta = (total_dn2(idof,iphase) - &
                     rt_auxvar_dn%total(idof,iphase)) / &
                    dc
          endif
          correction = 0.5d0*velocity_area*(1.d0+nu)* &
                       TFluxLimitPtr(theta)* &
                       dc
          flux(idof) = flux(idof) + correction
        enddo
      endif
    endif
  enddo

end subroutine TFluxTVD

! ************************************************************************** !

function TFluxLimiter(theta)
  !
  ! Applies flux limiter
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  implicit none

  PetscReal :: theta

  PetscReal :: TFluxLimiter

  ! Linear
  !---------
  ! upwind
  TFluxLimiter = 0.d0
  ! Lax-Wendroff
  !TFluxLimiter = 1.d0
  ! Beam-Warming
  !TFluxLimiter = theta
  ! Fromm
  !TFluxLimiter = 0.5d0*(1.d0+theta)

  ! Higher-order
  !---------
  ! minmod
  !TFluxLimiter = max(0.d0,min(1.d0,theta))
  ! superbee
  !TFluxLimiter = max(0.d0,min(1.d0,2.d0*theta),min(2.d0,theta))
  ! MC
  !TFluxLimiter = max(0.d0,min((1.d0+theta)/2.d0,2.d0,2.d0*theta))
  ! van Leer
  !TFluxLimiter = (theta+dabs(theta))/(1.d0+dabs(theta)

end function TFluxLimiter

! ************************************************************************** !

function TFluxLimitUpwind(theta)
  !
  ! Applies an upwind flux limiter
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  implicit none

  PetscReal :: theta

  PetscReal :: TFluxLimitUpwind

  ! upwind
  TFluxLimitUpwind = 0.d0

end function TFluxLimitUpwind

! ************************************************************************** !

function TFluxLimitMinmod(theta)
  !
  ! Applies a minmod flux limiter
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  implicit none

  PetscReal :: theta

  PetscReal :: TFluxLimitMinmod

  ! minmod
  TFluxLimitMinmod = max(0.d0,min(1.d0,theta))

end function TFluxLimitMinmod

! ************************************************************************** !

function TFluxLimitMC(theta)
  !
  ! Applies an MC flux limiter
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  implicit none

  PetscReal :: theta

  PetscReal :: TFluxLimitMC

 ! MC
  TFluxLimitMC = max(0.d0,min((1.d0+theta)/2.d0,2.d0,2.d0*theta))

end function TFluxLimitMC

! ************************************************************************** !

function TFluxLimitSuperBee(theta)
  !
  ! Applies an superbee flux limiter
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  implicit none

  PetscReal :: theta

  PetscReal :: TFluxLimitSuperBee

  ! superbee
  TFluxLimitSuperBee =  max(0.d0,min(1.d0,2.d0*theta),min(2.d0,theta))

end function TFluxLimitSuperBee

! ************************************************************************** !

function TFluxLimitVanLeer(theta)
  !
  ! Applies an van Leer flux limiter
  !
  ! Author: Glenn Hammond
  ! Date: 02/03/12
  !

  implicit none

  PetscReal :: theta

  PetscReal :: TFluxLimitVanLeer

  ! superbee
  TFluxLimitVanLeer = (theta+dabs(theta))/(1.d0+dabs(theta))

end function TFluxLimitVanLeer

! ************************************************************************** !

end module Transport_module
