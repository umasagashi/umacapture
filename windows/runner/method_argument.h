#pragma once

#include <string>
#include <variant>

namespace uma::windows::method_argument {

// Argument handling for the platform method channel, kept free of any Flutter type so it can be unit
// tested (native/test/runner/test_method_argument.cpp) without the generated cpp_client_wrapper headers.
//
// Everything below is templated on the value type rather than taking a flutter::EncodableValue: that class
// derives from a std::variant, and std::get_if deduces the base variant from a derived pointer, so the same
// code compiles against the real argument type and against a stand-in variant in the tests.
//
// The pointer is allowed to be null: flutter::MethodCall::arguments() is documented to return NULL when the
// call carries no argument at all, and a call that carries `null` decodes to the variant's monostate. Both
// used to be dereferenced unconditionally (`*std::get_if<std::string>(...)`), which is undefined behaviour
// for every payload that is not a string -- null, a bool, a number, a list, a map.

// Human-readable name of the alternative the argument holds, for log lines. Only the scalar alternatives
// are named individually; anything else (byte buffers, lists, maps, ...) reports as "other", which is
// enough to tell a caller that the payload type is wrong.
template<typename Value>
std::string typeName(const Value *arguments) {
    if (arguments == nullptr) {
        return "absent";
    } else if (std::get_if<std::monostate>(arguments) != nullptr) {
        return "null";
    } else if (std::get_if<bool>(arguments) != nullptr) {
        return "bool";
    } else if (std::get_if<int32_t>(arguments) != nullptr) {
        return "int32";
    } else if (std::get_if<int64_t>(arguments) != nullptr) {
        return "int64";
    } else if (std::get_if<double>(arguments) != nullptr) {
        return "double";
    } else if (std::get_if<std::string>(arguments) != nullptr) {
        return "string";
    } else {
        return "other";
    }
}

// Outcome of interpreting one incoming argument for one registered handler.
struct Decoded {
    // True when the handler may be invoked with `value`.
    bool ok = false;

    // The string to hand to the handler. Empty for a handler that takes no argument.
    std::string value;

    // Ready-to-log reason the call was rejected. Empty while `ok`.
    std::string error;
};

// Decides what a handler should receive.
//
// A handler registered WITHOUT an argument (startCapture, stopCapture, ...) never reads the string, so any
// payload is accepted and collapsed to an empty string; the Dart side is free to keep sending null.
//
// A handler registered WITH an argument only runs when the payload really is a string. Anything else is
// rejected with a message naming the method and the offending type, so the caller gets a channel error and
// the log gets a line, instead of the process reading through a null pointer.
template<typename Value>
Decoded decode(const std::string &method_name, bool takes_argument, const Value *arguments) {
    if (!takes_argument) {
        return {true, {}, {}};
    }
    if (arguments != nullptr) {
        if (const auto *text = std::get_if<std::string>(arguments); text != nullptr) {
            return {true, *text, {}};
        }
    }
    return {
        false,
        {},
        "Platform method '" + method_name + "' expects a string argument, but received " + typeName(arguments),
    };
}

}  // namespace uma::windows::method_argument
