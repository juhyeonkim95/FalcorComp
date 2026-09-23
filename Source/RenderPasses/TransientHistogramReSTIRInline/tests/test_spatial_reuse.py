"""GPU regression for shared reuse, identity preservation, and local-only paths.

Build the histogram pass and source bin/setpath.sh before running.
These checks exercise integration; they are not a proof of estimator unbiasedness.
"""
from pathlib import Path
import falcor
import numpy as np

def main():
    falcor.Logger.verbosity=falcor.Logger.Level.Error
    f=falcor.Testbed(create_window=False)
    f.load_scene(str((Path(__file__).resolve().parents[4] / 'experiments/scene/cornell-box/scene-v4-nolight.pbrt')))
    f.resize_frame_buffer(17,13); f.scene.camera.aspectRatio=17/13

    def render(iterations, neighbors=3, radius=8., threshold=.25, method='local_tangent', single=True, bin_reuse=False, time_range=(0., 40., 8)):
     g=f.create_render_graph('reuse')
     g.create_pass('V','VBufferRT',{'samplePattern':'Center','sampleCount':1})
     g.create_pass('L','LaserVBufferRT',{'laserPosition':[0.,1.7,6.8],'laserDirection':[0.,0.,-1.],'laserPower':[170.,120.,40.],'laserAngle':0.})
     g.create_pass('P','TransientHistogramReSTIRInline',{'samplesPerPixel':8,'timeMin':time_range[0],'timeMax':time_range[1],'timeBin':time_range[2],'timeGateMode':'box','useSingleChannel':single,'maxBounces':4,'spatialReuseIteration':iterations,'spatialReuseNeighborCount':neighbors,'spatialReuseGatherRadius':radius,'specularRoughnessThreshold':threshold,'shiftmapMethod':method,'gaugeMode':'avg_grad','useBinReuse':bin_reuse})
     for a,b in [('V.vbuffer','P.vbuffer'),('V.viewW','P.viewW'),('L.vbuffer','P.laservbuffer'),('L.viewW','P.laserviewW')]:g.add_edge(a,b)
     g.mark_output('P.histogram');g.mark_output('P.color');f.render_graph=g;f.frame()
     a=g.get_output('P.histogram').to_numpy().copy()
     assert np.isfinite(a).all() and a.max()>0
     color=g.get_output('P.color').to_numpy()
     integrated=a.sum(axis=0)*(time_range[1]-time_range[0])/time_range[2]
     if single:
      np.testing.assert_allclose(integrated.squeeze(),color[...,0],rtol=2e-5,atol=1e-5)
     else:
      np.testing.assert_allclose(integrated[...,:3],color[...,:3],rtol=2e-5,atol=1e-5)
     return a
    initial=render(0)
    for neighbors,radius in [(0,8.),(3,0.)]:
     np.testing.assert_allclose(initial,render(1,neighbors=neighbors,radius=radius),rtol=2e-5,atol=1e-5)
    print('Passed zero-neighbor and identity preservation',flush=True)
    render(1,threshold=1.)
    print('Passed local-only candidates',flush=True)
    for method in ['local_tangent','barycentric','ray_trace']:
     render(2,method=method)
     print('Passed histogram reuse:',method,flush=True)
    render(1,single=False)
    print('Passed RGB reuse and histogram/color consistency',flush=True)
    # Adjacent-bin shifts need bins narrow enough for the Newton solve (dt = one bin width).
    # With 5-unit bins nearly every shift is rejected and the canonical sample keeps full weight.
    narrow=(14.,30.,32)
    narrowInitial=render(0,time_range=narrow)
    assert not np.allclose(render(1,neighbors=0,bin_reuse=True,time_range=narrow),narrowInitial)
    render(2,bin_reuse=True,time_range=narrow)
    render(1,bin_reuse=True,single=False,time_range=narrow)
    print('Passed adjacent-bin reuse',flush=True)
    # Turn away from the scene on the existing graph to exercise background clearing.
    camera=f.scene.camera
    camera.target=falcor.float3(camera.position.x,camera.position.y,camera.position.z+1.)
    f.frame()
    graph=f.render_graph
    assert np.all(graph.get_output('P.histogram').to_numpy()[...,:3]==0)
    assert np.all(graph.get_output('P.color').to_numpy()[...,:3]==0)
    print('Passed background clearing across all bins',flush=True)


if __name__ == "__main__":
    main()
