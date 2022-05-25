#ifndef STDRV_TYPE_CHECK_H
#define STDRV_TYPE_CHECK_H

#include <type_traits>

namespace stdrv {
    namespace detail {
        template <class Default, class AlwaysVoid,
            template<class...> class Op, class... Args>
        struct detector {
            using value_t = std::false_type;
            using type = Default;
        };

        template <class Default, template<class...> class Op, class... Args>
        struct detector<Default, std::void_t<Op<Args...>>, Op, Args...> {
            using value_t = std::true_type;
            using type = Op<Args...>;
        };
    }
    struct nonesuch {
        nonesuch() = delete;
        ~nonesuch() = delete;
        nonesuch(nonesuch const&) = delete;
        void operator=(nonesuch const&) = delete;
    };

    template <template<class...> class Op, class... Args>
    using is_detected = typename detail::detector<nonesuch, void, Op, Args...>::value_t;

    template <typename F, typename ...Args>
    using call_operator_type = decltype(std::declval<F>()(std::declval<Args>()...));

    template <typename F, typename ...Args>
    using is_callable = is_detected<call_operator_type, F, Args...>;

    template <typename T>
    using begin_type = decltype(std::declval<T>().begin());

    template <typename T>
    using end_type = decltype(std::declval<T>().end());

    template <typename T>
    using is_iterable = std::conjunction<
        is_detected<begin_type, T>,
        is_detected<end_type, T>
    >;
}

#endif  //STDRV_TYPE_CHECK_H
