#pragma once
#include "Falcor.h"
#include <string>
#include <unordered_map>

using namespace Falcor;

/** Helpers for render pass configs (Shared/Host/Configs). A config is a group of render pass options that
 * parses and serializes its own properties and draws its own UI controls (renderUI functions return
 * true when a value changed). Render passes compose the configs they need:
 *   TimeGatedPathTracerInline:          TimeGateConfig + EllipsoidalSamplingConfig + PathTracingConfig
 *   TimeGatedReSTIRInline:              TimeGateConfig + EllipsoidalSamplingConfig + PathTracingConfig + PathLengthAwareReSTIRConfig
 *   TransientHistogramPathTracerInline: TransientHistogramConfig + PathTracingConfig
 *   TransientHistogramReSTIRInline:     TransientHistogramConfig + PathTracingConfig + PathLengthAwareReSTIRConfig
 */

/// Enum value named by a string property. Takes the property value itself: std::string(value) is ambiguous on
/// MSVC, because Properties::ConstValue converts to several of std::string's constructor argument types.
template<typename T>
T parseEnumProperty(const std::unordered_map<std::string, T>& values, const Properties::ConstValue& value, const std::string& key)
{
    const std::string name = value;
    auto it = values.find(name);
    if (it == values.end())
        FALCOR_THROW("Invalid value '{}' for '{}'.", name, key);
    return it->second;
}

template<typename T>
std::string enumPropertyName(const std::unordered_map<std::string, T>& values, T value)
{
    for (const auto& [name, candidate] : values)
        if (candidate == value)
            return name;
    FALCOR_THROW("Cannot serialize invalid enum value.");
}
