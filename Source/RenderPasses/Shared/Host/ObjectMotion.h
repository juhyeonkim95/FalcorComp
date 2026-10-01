#pragma once
#include "Falcor.h"
#include <map>
#include <string>
#include <vector>

using namespace Falcor;

/// Instantaneous rigid motion of a scene object: v(x) = linear + angular x (x - center). m/s, rad/s, scene units (m).
struct ObjectMotion
{
    float3 linear = float3(0.f);
    float3 angular = float3(0.f);
    float3 center = float3(0.f);

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
using ObjectMotions = std::map<std::string, ObjectMotion>;

/// Parses {"name": {"linear": [..], "angular": [..], "center": [..]}}; missing entries are zero.
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

/// Per geometry instance: linear, angular, center (float4 each), for StructuredBuffer<InstanceVelocity> in the shaders.
inline ref<Buffer> createInstanceVelocityBuffer(ref<Device> pDevice, const Scene& scene, const ObjectMotions& motions,
    const char* pass)
{
    const auto objects = listSceneObjects(scene);
    std::vector<float4> data(3 * std::max<size_t>(objects.size(), 1), float4(0.f));
    for (const auto& object : objects)
        for (const auto& [name, motion] : motions)
            if (object.matches(name))
            {
                data[3 * object.instance + 0] = float4(motion.linear, 0.f);
                data[3 * object.instance + 1] = float4(motion.angular, 0.f);
                data[3 * object.instance + 2] = float4(motion.center, 0.f);
            }
    warnUnmatchedObjects(objects, motions, pass);
    return pDevice->createStructuredBuffer(3 * sizeof(float4), (uint32_t)data.size() / 3, ResourceBindFlags::ShaderResource,
        MemoryType::DeviceLocal, data.data(), false);
}

/// Moves the scene-graph nodes of the named (movable) objects to their pose at a time t, and back. The pose at t = 0 is
/// the node transforms when prepare() is first called for the scene.
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
            for (const auto& [name, motion] : motions)
            {
                if (!object.matches(name))
                    continue;
                if (!object.movable)
                {
                    logWarning("{}: object '{}' is static and cannot move; build it as animated (e.g. "
                               "addTriangleMesh(..., isAnimated=True) in a .pyscene).", pass, name);
                    continue;
                }
                bool shared = false;
                for (const auto& node : mNodes)
                    shared |= node.id == object.node;
                if (shared)
                {
                    logWarning("{}: '{}' shares its scene-graph node with another moving object, so they cannot move "
                               "separately; load the scene with SceneBuilderFlags.DontOptimizeGraph.", pass, name);
                    continue;
                }
                mNodes.push_back({object.node, mBaseTransforms[object.node], motion});
            }
        }
        warnUnmatchedObjects(objects, motions, pass);
    }

    bool empty() const { return mNodes.empty(); }

    /// Sets the nodes to their pose at time t and updates the scene (the acceleration structure is rebuilt when it is
    /// next bound, e.g. by Scene::bindShaderDataForRaytracing).
    void apply(RenderContext* pRenderContext, float t)
    {
        for (const auto& node : mNodes)
            mpScene->updateNodeTransform(node.id, mul(node.motion.transformAt(t), node.base));
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
        float4x4 base;
        ObjectMotion motion;
    };
    ref<Scene> mpScene;
    std::vector<float4x4> mBaseTransforms;
    std::vector<Node> mNodes;
};
