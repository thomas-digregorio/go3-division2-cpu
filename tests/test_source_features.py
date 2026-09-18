"""Source-feature tests on original tiny fixtures; no full-case solve."""
from copy import deepcopy
import unittest

from fixtures import tiny_case, tiny_solution, tiny_source_features_case
from go3cpu.contract import require_supported
from go3cpu.independent import check, startup_window_violations
import test_contract_physics as oracle


class SourceFeatureTests(unittest.TestCase):
    def test_startup_window_membership_unequal_periods_and_empty_windows(self):
        dt=[0.5,1.0,0.25,0.25]
        starts=[1,0,1,0]
        windows=[[0,1.5,0],[1.5,2.0,0],[0,0,0],[2.0,2.0,0],
                 [1.5+5e-7,2.0,0],[0,1.5+5e-7,0],[0,1.5+2e-6,0]]
        self.assertEqual(startup_window_violations(windows,starts,dt),[1,1,0,0,1,1,2])

    def test_startup_counts_agree_with_official_at_time_boundaries(self):
        for window in ([0,1.5,0],[1.5,2.0,0],[0,0,0],[2,2,0],
                       [1.5+5e-7,2,0],[0,1.5+5e-7,0],[0,1.5+2e-6,1]):
            with self.subTest(window=window):
                c=tiny_case(dt=(0.5,1.0,0.25,0.25)); s=tiny_solution(c)
                g=c['network']['simple_dispatchable_device'][0]
                g.update(startups_ub=[window],in_service_time_lb=0.0,down_time_lb=0.0,
                         p_startup_ramp_ub=100.0,p_shutdown_ramp_ub=100.0)
                g['initial_status'].update(on_status=0,p=0.0,accu_up_time=0.0,accu_down_time=10.0)
                x=s['time_series_output']['simple_dispatchable_device'][0]
                x.update(on_status=[1,0,1,0],p_on=[0.2,0,0.2,0])
                ind,ev=check(c,s),oracle.OfficialCrossChecks().official(c,s)
                self.assertEqual(ind['hard_residuals']['maximum_startups'],
                                 ev.viol_sd_max_startup_constr['val'])

    def test_reactive_capability_includes_reserves_and_consumer_sign(self):
        for j in (0,1):
            for upper in (False,True):
                for violates in (False,True):
                    with self.subTest(device=j,upper=upper,violates=violates):
                        c=tiny_case(); s=tiny_solution(c)
                        g=c['network']['simple_dispatchable_device'][j]
                        g.update(q_bound_cap=1,q_0_ub=0.25,beta_ub=0.2,
                                 q_0_lb=-0.3,beta_lb=-0.1)
                        c['time_series_input']['simple_dispatchable_device'][j].update(
                            q_lb=[-2.0]*3,q_ub=[2.0]*3)
                        x=s['time_series_output']['simple_dispatchable_device'][j]
                        award=('q_res_up' if upper else 'q_res_down') if j==0 else (
                            'q_res_down' if upper else 'q_res_up')
                        x[award]=[0.02]*3
                        x['q']=[(0.44 if violates else 0.42) if upper else
                                (-0.39 if violates else -0.37)]*3
                        ind,ev=check(c,s),oracle.OfficialCrossChecks().official(c,s)
                        actual=ind['hard_residuals']['reactive_power_capability']
                        expected=0.01 if violates else 0.0
                        self.assertAlmostEqual(actual,expected)
                        field=f"viol_{'pr' if j==0 else 'cs'}_t_q_p_{'max' if upper else 'min'}"
                        self.assertAlmostEqual(actual,getattr(ev,field)['val'])
                        self.assertEqual(ev.get_feas(),0 if violates else 1)

    def test_reactive_capability_uses_startup_power_and_offline_status(self):
        c=tiny_case(dt=(1.0,0.25,0.25)); s=tiny_solution(c)
        g=c['network']['simple_dispatchable_device'][0]
        g.update(q_bound_cap=1,q_0_ub=0.3,beta_ub=0.2,q_0_lb=-0.3,beta_lb=-0.2,
                 p_startup_ramp_ub=1.0,p_shutdown_ramp_ub=1.0)
        g['initial_status'].update(on_status=0,p=0.0,accu_up_time=0.0,accu_down_time=10.0)
        c['time_series_input']['simple_dispatchable_device'][0]['p_lb']=[1.2]*3
        x=s['time_series_output']['simple_dispatchable_device'][0]
        x.update(on_status=[0,0,1],p_on=[0,0,1.2],q=[0.45,0.0,0.0])
        ind,ev=check(c,s),oracle.OfficialCrossChecks().official(c,s)
        self.assertAlmostEqual(ind['hard_residuals']['reactive_power_capability'],0.01)
        self.assertAlmostEqual(ev.viol_pr_t_q_p_max['val'],0.01)
        x.update(on_status=[0,0,0],p_on=[0,0,0],q=[0.01,0,0])
        ind,ev=check(c,s),oracle.OfficialCrossChecks().official(c,s)
        self.assertAlmostEqual(ind['hard_residuals']['reactive_power_capability'],0.01)
        self.assertAlmostEqual(ev.viol_pr_t_q_p_max['val'],0.01)

    def test_feature_gate_keeps_unknowns_and_invalid_coefficients_rejected(self):
        good=tiny_source_features_case(); before=deepcopy(good)
        require_supported(good)
        self.assertEqual(good,before)
        for window in ([-1,1,0],[1,0,0],[0,2,1],[0,1,-1],[0,1,0.5],[0,float('nan'),1]):
            bad=deepcopy(good); bad['network']['simple_dispatchable_device'][0]['startups_ub']=[window]
            with self.assertRaises(ValueError): require_supported(bad)
        bad=deepcopy(good); bad['network']['simple_dispatchable_device'][0]['q_linear_cap']=1
        with self.assertRaises(NotImplementedError): require_supported(bad)
        bad=deepcopy(good); bad['network']['simple_dispatchable_device'][0]['beta_lb']=float('nan')
        with self.assertRaises(ValueError): require_supported(bad)


if __name__=='__main__': unittest.main()
