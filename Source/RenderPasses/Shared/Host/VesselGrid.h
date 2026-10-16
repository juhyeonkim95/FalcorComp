#pragma once
#include "Falcor.h"
#include <pybind11/numpy.h>
#include <string>
#include <vector>

using namespace Falcor;

/// Blood vessels inside one medium (the Vessels of Shared/Shaders/Volumes/Media.slang): over a box, grids of the
/// blood fraction and of the blood's velocity, and the blood's optical properties. The medium mixes its own
/// coefficients with the blood's by the fraction.
class VesselGrid
{
public:
    using Array = pybind11::array_t<float, pybind11::array::c_style | pybind11::array::forcecast>;

    /// Blood in the medium of material `medium`: `fraction` (nz, ny, nx) and `velocity` (nz, ny, nx, 3) m/s, at the
    /// centers of the cells of the box from `origin` to `origin + size` (x along the last axis); scattering and
    /// absorption per meter, the Henyey-Greenstein g, and the Brownian diffusion coefficient (m^2/s).
    void set(ref<Device> pDevice, const std::string& medium, const Array& fraction, const Array& velocity, float3 origin,
        float3 size, float3 scattering, float3 absorption, float anisotropy, float diffusion)
    {
        if (fraction.ndim() != 3 || velocity.ndim() != 4 || velocity.shape(3) != 3)
            FALCOR_THROW("Vessels: fraction must be (nz, ny, nx) and velocity (nz, ny, nx, 3).");
        for (int i = 0; i < 3; ++i)
            if (fraction.shape(i) != velocity.shape(i))
                FALCOR_THROW("Vessels: fraction and velocity must have the same grid.");
        const uint32_t nz = uint32_t(fraction.shape(0)), ny = uint32_t(fraction.shape(1)), nx = uint32_t(fraction.shape(2));
        std::vector<float4> velocity4(size_t(nx) * ny * nz);
        const float* v = velocity.data();
        for (size_t i = 0; i < velocity4.size(); ++i)
            velocity4[i] = float4(v[3 * i], v[3 * i + 1], v[3 * i + 2], 0.f);
        mpFraction = pDevice->createTexture3D(nx, ny, nz, ResourceFormat::R32Float, 1, fraction.data());
        mpVelocity = pDevice->createTexture3D(nx, ny, nz, ResourceFormat::RGBA32Float, 1, velocity4.data());
        mMedium = medium;
        mOrigin = origin;
        mSize = size;
        mScattering = scattering;
        mAbsorption = absorption;
        mAnisotropy = anisotropy;
        mDiffusion = diffusion;
        mWarned = false;
    }

    void clear()
    {
        mpFraction = nullptr;
        mpVelocity = nullptr;
        mMedium.clear();
    }

    /// Binds the Vessels of Media.slang: none if unset or if no material is named as its medium (logged once).
    void bindShaderData(ref<Device> pDevice, const ShaderVar& var, const Scene& scene, const char* pass)
    {
        if (!mpSampler)
        {
            Sampler::Desc desc;
            desc.setFilterMode(TextureFilteringMode::Linear, TextureFilteringMode::Linear, TextureFilteringMode::Point);
            desc.setAddressingMode(TextureAddressingMode::Clamp, TextureAddressingMode::Clamp, TextureAddressingMode::Clamp);
            mpSampler = pDevice->createSampler(desc);
            const float zero[4] = {};
            mpDummyFraction = pDevice->createTexture3D(1, 1, 1, ResourceFormat::R32Float, 1, zero);
            mpDummyVelocity = pDevice->createTexture3D(1, 1, 1, ResourceFormat::RGBA32Float, 1, zero);
        }
        uint32_t material = kNone;
        if (mpFraction)
        {
            for (uint32_t i = 0; i < scene.getMaterialCount(); ++i)
                if (scene.getMaterial(MaterialID(i))->getName() == mMedium)
                    material = i;
            if (material == kNone && !mWarned)
            {
                logWarning("{}: no material is named '{}' (vessels).", pass, mMedium);
                mWarned = true;
            }
        }
        auto cb = var["Vessels"];
        cb["gVesselMaterial"] = material;
        cb["gVesselOrigin"] = mOrigin;
        cb["gVesselSize"] = mSize;
        cb["gBloodScattering"] = mScattering;
        cb["gBloodAbsorption"] = mAbsorption;
        cb["gBloodAnisotropy"] = mAnisotropy;
        cb["gBloodDiffusion"] = mDiffusion;
        var["gVesselFraction"] = material != kNone ? mpFraction : mpDummyFraction;
        var["gVesselVelocity"] = material != kNone ? mpVelocity : mpDummyVelocity;
        var["gVesselSampler"] = mpSampler;
    }

private:
    static constexpr uint32_t kNone = 0xffffffff; ///< kNoVessels in Media.slang.
    ref<Texture> mpFraction;
    ref<Texture> mpVelocity;
    ref<Texture> mpDummyFraction;
    ref<Texture> mpDummyVelocity;
    ref<Sampler> mpSampler;
    std::string mMedium;
    float3 mOrigin = float3(0.f);
    float3 mSize = float3(1.f);
    float3 mScattering = float3(0.f);
    float3 mAbsorption = float3(0.f);
    float mAnisotropy = 0.f;
    float mDiffusion = 0.f;
    bool mWarned = false;
};
