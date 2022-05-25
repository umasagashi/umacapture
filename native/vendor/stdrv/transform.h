#ifndef STDRV_TRANSFORM_H
#define STDRV_TRANSFORM_H

#include <algorithm>
#include <cassert>
#include <map>
#include <type_traits>

#include "stdrv/type_check.h"

namespace stdrv {
    template <
        typename F,
        typename V
    >
    struct unary_transform_type_check {
        static_assert(
            is_iterable<V>::value,
            "Please input itarable object.");
        static_assert(
            is_callable<F, typename V::value_type>::value,
            "Please input unary fucntion.");
    };

    template <
        template <typename ...> typename R,
        typename F,
        typename V
    >
    struct unary_transform_impl : private unary_transform_type_check<F, V> {
        using functor_result_type = call_operator_type<F, typename V::value_type>;
        using result_type = R<functor_result_type>;

        static result_type apply(const V& v, F&& unary) {
            result_type ret(v.size());
            std::transform(
                std::cbegin(v),
                std::cend(v),
                std::begin(ret),
                unary);
            return ret;
        }
    };

    template <
        typename F,
        typename V
    >
    struct unary_transform_impl<std::map, F, V> : private unary_transform_type_check<F, V> {
        using functor_result_type = call_operator_type<F, typename V::value_type>;
        using result_type = std::map<
            typename functor_result_type::first_type,
            typename functor_result_type::second_type
        >;

        static result_type apply(const V& v, F&& unary) {
            result_type ret{};
            std::transform(
                std::cbegin(v),
                std::cend(v),
                std::inserter(ret, ret.begin()),
                unary);
            return ret;
        }
    };

    template <
        template <typename ...> typename R,
        typename F,
        typename V
    > 
    inline typename unary_transform_impl<R, F, V>::result_type
    transform(const V& v, F&& unary)
    {
        return unary_transform_impl<R, F, V>::apply(v, std::forward<F>(unary));
    }

    template <
        typename F,
        typename V0,
        typename V1
    >
    struct binary_transform_type_check {
        static_assert(
            is_iterable<V0>::value,
            "Please input itarable object.");
        static_assert(
            is_iterable<V1>::value,
            "Please input itarable object.");
        static_assert(
            is_callable<F, typename V0::value_type, typename V1::value_type>::value,
            "Please input unary fucntion.");
    };

    template <
        template <typename ...> typename R,
        typename F,
        typename V0,
        typename V1
    >
    struct binary_transform_impl : private binary_transform_type_check<F, V0, V1> {
        using functor_result_type
            = call_operator_type<F, typename V0::value_type, typename V1::value_type>;
        using result_type = R<functor_result_type>;

        static result_type apply(const V0& v0, const V0& v1, F&& binary) {
            assert(v0.size() == v1.size());

            result_type ret(v0.size());
            std::transform(
                std::cbegin(v0),
                std::cend(v0),
                std::cbegin(v1),
                std::begin(ret),
                binary);
            return ret;
        }
    };

    template <
        typename F,
        typename V0,
        typename V1
    >
    struct binary_transform_impl<std::map, F, V0, V1> : private binary_transform_type_check<F, V0, V1> {
        using functor_result_type
            = call_operator_type<F, typename V0::value_type, typename V1::value_type>;
        using result_type = std::map<
            typename functor_result_type::first_type,
            typename functor_result_type::second_type
        >;

        static result_type apply(const V0& v0, const V1& v1, F&& binary) {
            assert(v0.size() == v1.size());

            result_type ret{};
            std::transform(
                std::cbegin(v0),
                std::cend(v0),
                std::cbegin(v1),
                std::inserter(ret, ret.begin()),
                binary);
            return ret;
        }
    };

    template <
        template <typename ...> typename R,
        typename F,
        typename V0,
        typename V1
    > 
    inline typename binary_transform_impl<R, F, V0, V1>::result_type
    transform(const V0& v0, const V1& v1, F&& binary)
    {
        return binary_transform_impl<R, F, V0, V1>::apply(v0, v1, std::forward<F>(binary));
    }
}

#endif  //STDRV_TRANSFORM_H
