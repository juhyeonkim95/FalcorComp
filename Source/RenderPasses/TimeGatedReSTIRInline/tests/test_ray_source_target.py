"""GPU regression of production ray SurfaceOps against a deterministic plane.

Only scene intersection/vertex lookup are replaced by a plane fixture. The actual
SurfaceOps implementation tests separate endpoints, derivatives, and hit caching.
Source the build's bin/setpath.sh before running.
"""
from pathlib import Path
import tempfile
import falcor
import numpy as np


def main():
    source = (Path(__file__).resolve().parents[1] / 'SurfaceOps/RayTraceHemisphere.slang').read_text()
    production_ops = source[source.index('export struct RayTraceHemisphereOps'):]
    shader = '''
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.SurfaceOpsInterface;
import RenderPasses.TimeGatedReSTIRInline.NewtonSolver;
import RenderPasses.TimeGatedReSTIRInline.SurfaceOps.CartesianRayChart;
#include "Utils/Math/MathConstants.slangh"
RWStructuredBuffer<float4> results;
// A deterministic infinite triangle plane, replacing only the scene API.
float3 planeNormal() { return normalize(float3(.2f,-.1f,1.f)); }
enum HitType { Triangle };
struct TriangleHit { float3 position; };
struct HitInfo
{
    bool valid; float3 position;
    __init() { valid = false; position = float3(0.f); }
    bool isValid() { return valid; }
    HitType getType() { return HitType::Triangle; }
    TriangleHit getTriangleHit() { TriangleHit t; t.position=position; return t; }
};
struct VertexData { float3 posW; float3 faceNormalW; };
struct PlaneScene
{
    VertexData getVertexData(TriangleHit t)
    { VertexData v; v.posW=t.position; v.faceNormalW=planeNormal(); return v; }
};
static PlaneScene gScene;
struct Ray
{
    float3 origin, direction; float tmin,tmax;
    __init(float3 o,float3 d,float a,float b) { origin=o;direction=d;tmin=a;tmax=b; }
};
struct SceneRayQuery<let UseAlphaTest : int>
{
    HitInfo traceRay(Ray ray, out float t)
    {
        float3 n=planeNormal();
        t=(2.f-dot(n,ray.origin))/dot(n,ray.direction);
        HitInfo hit; hit.valid=t>ray.tmin && t<ray.tmax;
        hit.position=ray.origin+t*ray.direction; return hit;
    }
};
''' + production_ops + '''
RayTraceHemisphereOps makeOps(bool cartesian)
{
    RayTraceHemisphereOps ops = RayTraceHemisphereOps(float3(-.5f,.3f,.4f),float3(.3f,-.4f,.6f),
        float3(0.f,0.f,.05f),float3(0.f),float3(1.f,0.f,0.f),float3(0.f,1.f,0.f),float3(0.f,0.f,1.f));
    ops.useCartesianChart=cartesian; return ops;
}
bool evaluate(float2 point,bool cartesian,bool source,out float L,out float2 g,out float3 H)
{
    RayTraceHemisphereOps ops=makeOps(cartesian); ops.initializeSource(point);
    if(source) return ops.evalSource(point,L,g,H);
    return ops.evalTarget(point,L,g,H);
}
NewtonResult mapped(float2 xi,bool cartesian)
{
    RayTraceHemisphereOps ops=makeOps(cartesian);
    ops.targetP1=float3(-.45f,.32f,.4f);
    return solve_xi_prime_newton_det(ops,xi,0.f,GaugeMode::ORTHO_AVG_GRAD,float2(0.f,1.f),30,1e-6f);
}
[numthreads(1,1,1)]
void main(uint3 tid:SV_DispatchThreadID)
{
    for(uint index=0;index<4;++index)
    {
        bool cartesian=index/2!=0, source=index%2!=0;
        float2 xi=cartesian?float2(.3f,.2f):float2(.8f,.12f);
        float h=.001f;
        float L,lp,lm,vp,vm; float2 g,gp,gm,hp,hm; float3 H,tmp;
        bool ok=evaluate(xi,cartesian,source,L,g,H);
        ok=evaluate(xi+float2(h,0.f),cartesian,source,lp,gp,tmp)&&ok;
        ok=evaluate(xi-float2(h,0.f),cartesian,source,lm,gm,tmp)&&ok;
        ok=evaluate(xi+float2(0.f,h),cartesian,source,vp,hp,tmp)&&ok;
        ok=evaluate(xi-float2(0.f,h),cartesian,source,vm,hm,tmp)&&ok;
        float2 gradFD=float2(lp-lm,vp-vm)/(2.f*h);
        float3 hessFD=float3(gp.x-gm.x,gp.y-gm.y,hp.y-hm.y)/(2.f*h);
        results[2*index]=float4(length(g-gradFD)/max(1.f,length(g)),
            length(H-hessFD)/max(1.f,length(H)),abs((hp.x-hm.x)/(2.f*h)-H.y)/max(1.f,length(H)),float(!ok));

        RayTraceHemisphereOps ops=makeOps(cartesian); ops.initializeSource(xi);
        float Lbefore,Lafter; float2 gbefore,gafter; float3 Hbefore,Hafter;
        ok=ops.evalSource(xi,Lbefore,gbefore,Hbefore);
        float2 xi_prime=xi+float2(.01f,.02f); ops.update(xi_prime);
        ok=ops.evalSource(xi,Lafter,gafter,Hafter)&&ok;
        ok=ops.evalTarget(xi_prime,L,g,H)&&ok;
        float3 targetPoint=ops.hit.position;
        float expected=length(ops.targetP1-targetPoint)+length(ops.p2-targetPoint);
        bool wrongTarget=ops.evalTarget(xi,lp,gp,tmp);
        bool wrongSource=ops.evalSource(xi_prime,lp,gp,tmp);
        results[2*index+1]=float4(abs(Lbefore-Lafter)+length(gbefore-gafter)+length(Hbefore-Hafter),
            abs(L-expected),float(wrongTarget||wrongSource),float(!ok));
    }
    for(uint j=0;j<2;++j)
    {
        bool cartesian=j!=0;
        float2 xi=cartesian?float2(.3f,.2f):float2(.8f,.12f);
        float h=.001f;
        NewtonResult center=mapped(xi,cartesian);
        NewtonResult xp=mapped(xi+float2(h,0.f),cartesian),xm=mapped(xi-float2(h,0.f),cartesian);
        NewtonResult yp=mapped(xi+float2(0.f,h),cartesian),ym=mapped(xi-float2(0.f,h),cartesian);
        float2 dx=(xp.xi_prime-xm.xi_prime)/(2.f*h),dy=(yp.xi_prime-ym.xi_prime)/(2.f*h);
        results[8+j]=float4(center.detJ,abs(dx.x*dy.y-dx.y*dy.x),
            float(uint(center.status)+uint(xp.status)+uint(xm.status)+uint(yp.status)+uint(ym.status)),0.f);
    }
}
'''
    testbed=falcor.Testbed(create_window=False)
    device=testbed.device
    output=device.create_structured_buffer(struct_size=16,element_count=10,
        bind_flags=falcor.ResourceBindFlags.ShaderResource|falcor.ResourceBindFlags.UnorderedAccess)
    with tempfile.TemporaryDirectory(prefix='ray-source-target-') as directory:
        path=Path(directory)/'test.cs.slang';path.write_text(shader)
        compute=falcor.ComputePass(device,file=path,cs_entry='main')
        compute.globals.results=output
        compute.execute(threads_x=1);device.wait()
        rows=output.to_numpy().view(np.float32).reshape(10,4)
    print(rows)
    assert np.isfinite(rows).all(),rows
    assert np.all(rows[:8:2,:3]<.004),rows
    assert np.all(rows[:,3]==0),rows
    np.testing.assert_allclose(rows[1:8:2,:3],0.,atol=1e-6)
    assert np.all(rows[8:,2]==0),rows[8:]
    np.testing.assert_allclose(rows[8:,0],rows[8:,1],rtol=.003,atol=.0002)
    print('Polar and Cartesian: source/target derivatives and fixed source hit passed.')


if __name__=='__main__':
    main()
