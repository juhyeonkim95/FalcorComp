#pragma once
#include "Falcor.h"
#include <map>
#include <string>
#include <vector>

using namespace Falcor;

/// Motion of a scene object: its instantaneous rigid motion, v(x) = linear + angular x (x - center), and, for the
/// scatterers of a medium, a Poiseuille flow and Brownian motion. m/s, rad/s, scene units (m).
struct ObjectMotion
{
    float3 linear = float3(0.f);
    float3 angular = float3(0.f);
    float3 center = float3(0.f);
    /// Poiseuille flow, added to the rigid motion: flowMaxSpeed (1 - r^2 / flowRadius^2) along flowAxis (a unit
    /// vector) at distance r < flowRadius from the axis through flowOrigin, zero farther out.
    float3 flowOrigin = float3(0.f);
    float3 flowAxis = float3(0.f, 0.f, 1.f);
    float flowRadius = 0.f;
    float flowMaxSpeed = 0.f;
    /// Brownian diffusion coefficient of the scatterers (m^2/s), around their motion above.
    float diffusion = 0.f;

    bool hasFlow() const { return flowMaxSpeed != 0.f && flowRadius > 0.f; }

    /// World transform taking the object's pose at time 0 to its pose at time t (rotation about center, then the
    /// translation linear t).
    float4x4 transformAt(float t) const
    {
        float4x4 motion = math::matrixFromTranslation(linear * t);
        const float angle = length(angular) * t;
        if (angle != 0.f)
        {
            const float4x4 rotation = math::matrixFromRotation(angle, normalize(angular));
            motion = mul(motion, mul(math::matrixFromTranslation(center), mul(rotation, math::matrixFromTranslation(-center))));
        }
        return motion;
    }
};

/// Object name -> motion. Names match a geometry instance's mesh name, its material name, or "#<instance index>".
/// Motions are in world space, also for an object whose scene-graph node has a parent.
using ObjectMotions = std::map<std::string, ObjectMotion>;

/// Parses {"name": {"linear": [..], "angular": [..], "center": [..], "flowOrigin": [..], "flowAxis": [..],
/// "flowRadius": .., "flowMaxSpeed": .., "diffusion": ..}}; missing entries are zero (flowAxis: z). flowAxis is
/// normalized (it must not be zero).
inline ObjectMotions parseObjectMotions(const Properties& objects)
{
    ObjectMotions motions;
    for (const auto& [name, value] : objects)
    {
        const Properties props = value;
        ObjectMotion motion;
        motion.linear = props.get<float3>("linear", float3(0.f));
        motion.angular = props.get<float3>("angular", float3(0.f));
        motion.center = props.get<float3>("center", float3(0.f));
        motion.flowOrigin = props.get<float3>("flowOrigin", float3(0.f));
        motion.flowAxis = normalize(props.get<float3>("flowAxis", float3(0.f, 0.f, 1.f)));
        motion.flowRadius = props.get<float>("flowRadius", 0.f);
        motion.flowMaxSpeed = props.get<float>("flowMaxSpeed", 0.f);
        motion.diffusion = props.get<float>("diffusion", 0.f);
        motions[name] = motion;
    }
    return motions;
}

inline Properties serializeObjectMotions(const ObjectMotions& motions)
{
    Properties objects;
    for (const auto& [name, motion] : motions)
    {
        Properties props;
        props["linear"] = motion.linear;
        props["angular"] = motion.angular;
        props["center"] = motion.center;
        if (motion.hasFlow())
        {
            props["flowOrigin"] = motion.flowOrigin;
            props["flowAxis"] = motion.flowAxis;
            props["flowRadius"] = motion.flowRadius;
            props["flowMaxSpeed"] = motion.flowMaxSpeed;
        }
        if (motion.diffusion != 0.f)
            props["diffusion"] = motion.diffusion;
        objects[name] = props;
    }
    return objects;
}

/// A geometry instance of the scene and the names it can be referred to by.
struct SceneObject
{
    uint32_t instance;
    std::string mesh;
    std::string material;
    bool movable;  ///< Built as dynamic (e.g. addTriangleMesh(..., isAnimated=True)): its node can be moved.
    uint32_t node; ///< Scene-graph node of its transform.

    bool matches(const std::string& name) const
    {
        return name == mesh || name == material || name == "#" + std::to_string(instance);
    }
};

/// The motion an object takes: that of its most specific listed name, "#<instance>" over its mesh name over its
/// material name (e.g. a material name moves every object with that material but the ones listed by mesh). The same
/// in every pass; nullptr if no name is listed.
inline const ObjectMotions::value_type* findObjectMotion(const ObjectMotions& motions, const SceneObject& object)
{
    for (const std::string& name : {"#" + std::to_string(object.instance), object.mesh, object.material})
    {
        if (name.empty())
            continue;
        if (auto it = motions.find(name); it != motions.end())
            return &*it;
    }
    return nullptr;
}

inline std::vector<SceneObject> listSceneObjects(const Scene& scene)
{
    std::vector<SceneObject> objects;
    for (uint32_t i = 0; i < scene.getGeometryInstanceCount(); ++i)
    {
        const GeometryInstanceData& instance = scene.getGeometryInstance(i);
        const std::string mesh = instance.getType() == GeometryType::TriangleMesh ? scene.getMeshName(instance.geometryID) : "";
        objects.push_back({i, mesh, scene.getMaterial(MaterialID(instance.materialID))->getName(), instance.isDynamic(),
                           instance.globalMatrixID});
    }
    return objects;
}

/// Logs the names of `motions` that match no scene object.
inline void warnUnmatchedObjects(const std::vector<SceneObject>& objects, const ObjectMotions& motions, const char* pass)
{
    for (const auto& [name, motion] : motions)
    {
        bool found = false;
        for (const auto& object : objects)
            found |= object.matches(name);
        if (!found)
            logWarning("{}: no scene object is named '{}' (mesh or material name, or #<instance>).", pass, name);
    }
}

/// Per geometry instance, StructuredBuffer<InstanceVelocity> in the shaders (PathVelocity.slang): linear, angular,
/// center, (flowOrigin, flowRadius), (flowAxis, flowMaxSpeed or 0 without a flow), (diffusion, 0, 0, 0).
inline ref<Buffer> createInstanceVelocityBuffer(ref<Device> pDevice, const Scene& scene, const ObjectMotions& motions,
    const char* pass)
{
    constexpr size_t kStride = 6;
    const auto objects = listSceneObjects(scene);
    std::vector<float4> data(kStride * std::max<size_t>(objects.size(), 1), float4(0.f));
    for (const auto& object : objects)
        if (const auto* entry = findObjectMotion(motions, object))
        {
            const ObjectMotion& motion = entry->second;
            float4* v = &data[kStride * object.instance];
            v[0] = float4(motion.linear, 0.f);
            v[1] = float4(motion.angular, 0.f);
            v[2] = float4(motion.center, 0.f);
            v[3] = float4(motion.flowOrigin, motion.flowRadius);
            v[4] = float4(motion.flowAxis, motion.hasFlow() ? motion.flowMaxSpeed : 0.f);
            v[5] = float4(motion.diffusion, 0.f, 0.f, 0.f);
        }
    warnUnmatchedObjects(objects, motions, pass);
    return pDevice->createStructuredBuffer(kStride * sizeof(float4), (uint32_t)(data.size() / kStride),
        ResourceBindFlags::ShaderResource, MemoryType::DeviceLocal, data.data(), false);
}

/// Moves the scene-graph nodes of the named (movable) objects to their pose at a time t, and back. The pose at t = 0 is
/// the node transforms when prepare() is first called for the scene. Motions are in world space, as the velocity
/// buffers above: a node with a parent moves by the same world transform as a root node, and a moving node below
/// another one keeps its own motion instead of adding its ancestor's.
class SceneMover
{
public:
    /// Collects the nodes to move. Restores any node moved before.
    void prepare(const ref<Scene>& pScene, const ObjectMotions& motions, const char* pass)
    {
        restore();
        if (pScene != mpScene)
        {
            mpScene = pScene;
            mBaseTransforms = pScene->getAnimationController()->getLocalMatrices();
        }
        mNodes.clear();
        const auto objects = listSceneObjects(*pScene);
        for (const auto& object : objects)
        {
            const auto* entry = findObjectMotion(motions, object);
            if (!entry)
                continue;
            const auto& [name, motion] = *entry;
            if (motion.hasFlow() || motion.diffusion != 0.f)
                logWarning("{}: the flow and diffusion of '{}' move no geometry (only the scatterers of a medium, in "
                           "DopplerHistogramPathTracerInline); its rigid motion does.", pass, name);
            if (!object.movable)
            {
                logWarning("{}: object '{}' is static and cannot move; build it as animated (e.g. "
                           "addTriangleMesh(..., isAnimated=True) in a .pyscene).", pass, name);
                continue;
            }
            // The objects of one node move together: only a different motion conflicts.
            if (const int other = findNode(object.node); other >= 0)
            {
                if (!sameMotion(mNodes[other].motion, motion))
                    logWarning("{}: '{}' shares its scene-graph node with another moving object, so they cannot move "
                               "separately; load the scene with SceneBuilderFlags.DontOptimizeGraph.", pass, name);
                continue;
            }
            const float4x4 parent = getBaseParentTransform(object.node);
            mNodes.push_back({object.node, mBaseTransforms[object.node], parent, inverse(parent), motion, -1});
        }
        for (auto& node : mNodes)
            node.movingAncestor = findMovingAncestor(mpScene->getParentNodeID(NodeID{node.id}));
        // An unlisted object on a moving node, or below one, moves with it here, but the velocity buffers leave it at
        // rest.
        for (const auto& object : objects)
            if (object.movable && !findObjectMotion(motions, object) && findMovingAncestor(NodeID{object.node}) >= 0)
                logWarning("{}: object #{} ('{}') is attached to a moving object in the scene graph and moves with it, "
                           "but has no velocity of its own; list it with the same motion.", pass, object.instance,
                           object.mesh.empty() ? object.material : object.mesh);
        warnUnmatchedObjects(objects, motions, pass);
    }

    bool empty() const { return mNodes.empty(); }

    /// Sets the nodes to their pose at time t and updates the scene (the acceleration structure is rebuilt when it is
    /// next bound, e.g. by Scene::bindShaderDataForRaytracing).
    void apply(RenderContext* pRenderContext, float t)
    {
        std::vector<float4x4> motions(mNodes.size());
        for (size_t i = 0; i < mNodes.size(); ++i)
            motions[i] = mNodes[i].motion.transformAt(t);
        for (size_t i = 0; i < mNodes.size(); ++i)
        {
            // World-space motion M of a node with parent P: local transform P^-1 M P base. Below a moving node A, the
            // parent has moved by M_A, which M_A^-1 undoes.
            const Node& node = mNodes[i];
            const float4x4 motion = node.movingAncestor >= 0 ? mul(inverse(motions[node.movingAncestor]), motions[i]) : motions[i];
            mpScene->updateNodeTransform(node.id, mul(node.parentInverse, mul(motion, mul(node.parent, node.base))));
        }
        mpScene->update(pRenderContext, 0.0);
    }

    /// Puts the nodes back at their base pose (applied by the next scene update).
    void restore()
    {
        if (!mpScene)
            return;
        for (const auto& node : mNodes)
            mpScene->updateNodeTransform(node.id, node.base);
    }

    void reset()
    {
        restore();
        mNodes.clear();
        mBaseTransforms.clear();
        mpScene = nullptr;
    }

private:
    struct Node
    {
        uint32_t id;
        float4x4 base;          ///< Local transform at time 0.
        float4x4 parent;        ///< World transform of the parent at time 0 (identity for a root node).
        float4x4 parentInverse;
        ObjectMotion motion;
        int movingAncestor;     ///< Index in mNodes of the nearest moving ancestor, or -1.
    };

    static bool sameMotion(const ObjectMotion& a, const ObjectMotion& b)
    {
        return all(a.linear == b.linear) && all(a.angular == b.angular) && all(a.center == b.center);
    }

    /// Index in mNodes of scene-graph node `node`, or -1.
    int findNode(uint32_t node) const
    {
        for (size_t i = 0; i < mNodes.size(); ++i)
            if (mNodes[i].id == node)
                return int(i);
        return -1;
    }

    /// Index in mNodes of `node` or of its nearest ancestor that moves, or -1.
    int findMovingAncestor(NodeID node) const
    {
        for (; node.isValid(); node = mpScene->getParentNodeID(node))
            if (const int i = findNode(node.get()); i >= 0)
                return i;
        return -1;
    }

    /// World transform of the parent of `node` at time 0, from the base local transforms (identity for a root node).
    float4x4 getBaseParentTransform(uint32_t node) const
    {
        float4x4 transform = float4x4::identity();
        for (NodeID parent = mpScene->getParentNodeID(NodeID{node}); parent.isValid(); parent = mpScene->getParentNodeID(parent))
            transform = mul(mBaseTransforms[parent.get()], transform);
        return transform;
    }

    ref<Scene> mpScene;
    std::vector<float4x4> mBaseTransforms;
    std::vector<Node> mNodes;
};
