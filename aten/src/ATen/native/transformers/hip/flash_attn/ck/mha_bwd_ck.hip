/******************************************************************************
 * Copyright (c) 2024, Tri Dao.
 ******************************************************************************/

#include <ATen/native/transformers/hip/flash_attn/flash_common_hip.hpp>
#include <mha_bwd.h>
#include <fmha_bwd.hpp>
#include <mask.hpp>

namespace pytorch_flash {

fmha_bwd_traits get_ck_fmha_bwd_traits(const mask_info &mask,
                                       std::string dtype,
                                       int head_size,
                                       bool has_dropout,
                                       bool enable_bias,
                                       bool deterministic,
                                       bool bias_requires_grad)
{
    return fmha_bwd_traits{head_size,
                           head_size,
                           dtype,
                           false, // is_group_mode
                           mask.type,
                           enable_bias ? bias_enum::elementwise_bias : bias_enum::no_bias,
                           bias_requires_grad,    // has_dbias
                           has_dropout,
                           false, // s_randval
                           deterministic};
}



aiter::mha_bwd_traits get_mha_bwd_traits(fmha_bwd_traits t, mask_info mask)
{
    return aiter::mha_bwd_traits(t.hdim_q,
                          t.hdim_v,
                          t.data_type,
                          t.is_group_mode,
                          mask.type,
                          t.bias_type,
                          t.has_dbias,
                          t.has_dropout,
                          t.is_store_randval,
                          t.is_deterministic,
                          true,                  // use_ext_asm
                          true,                  // is_v3_atomic_fp32,
                          1);                    // how_v3_bf16_cvt

}

fmha_bwd_args get_ck_fmha_bwd_args(const mask_info &mask,
                                   // sizes
                                   const int b,
                                   const int seqlen_q,
                                   const int seqlen_k,
                                   const int h,
                                   const int h_k,
                                   const int hdim,
                                   // device pointers
                                   const at::Tensor q,
                                   const at::Tensor k,
                                   const at::Tensor v,
                                   std::optional<at::Tensor> &attn_bias_,
                                   bool bias_requires_grad,
                                   std::optional<at::Tensor> &grad_bias,
                                   const at::Tensor out,
                                   const at::Tensor softmax_lse,
                                   const at::Tensor dout,
                                   at::Tensor dq_acc,
                                   at::Tensor d,
                                   at::Tensor dq,
                                   at::Tensor dk,
                                   at::Tensor dv,
                                   float softmax_scale,
                                   float p_dropout,
                                   std::pair<uint64_t*, uint64_t*> drop_seed_offset)
{
    // q: (batch_size, seqlen_q, nheads, hdim)
    ck_tile::index_t batch_stride_q = q.stride(0);
    ck_tile::index_t stride_q = q.stride(1);
    ck_tile::index_t nhead_stride_q = q.stride(2);

    // k: (batch_size, seqlen_k, nheads_k, hdim)
    ck_tile::index_t batch_stride_k = k.stride(0);
    ck_tile::index_t stride_k = k.stride(1);
    ck_tile::index_t nhead_stride_k = k.stride(2);

    // v: (batch_size, seqlen_k, nheads_k, hdim)
    ck_tile::index_t batch_stride_v = v.stride(0);
    ck_tile::index_t stride_v = v.stride(1);
    ck_tile::index_t nhead_stride_v = v.stride(2);

    // o: (batch_size, seqlen_q, nheads, hdim)
    ck_tile::index_t batch_stride_o = out.stride(0);
    ck_tile::index_t stride_o = out.stride(1);
    ck_tile::index_t nhead_stride_o = out.stride(2);

    // lse: (batch_size, nheads, seqlen_q)
    ck_tile::index_t batch_stride_lse = softmax_lse.stride(0);
    ck_tile::index_t nhead_stride_lse = softmax_lse.stride(1);

    // do: (batch_size, seqlen_q, nheads, hdim)
    ck_tile::index_t batch_stride_do = dout.stride(0);
    ck_tile::index_t stride_do = dout.stride(1);
    ck_tile::index_t nhead_stride_do = dout.stride(2);

    // d: (batch_size, nheads, seqlen_q)

    // dq: (batch_size, seqlen_q, nheads, hdim)
    ck_tile::index_t batch_stride_dq = dq.stride(0);
    ck_tile::index_t stride_dq = dq.stride(1);
    ck_tile::index_t nhead_stride_dq = dq.stride(2);

    // dk_expanded: (batch_size, seqlen_k, nheads, hdim)
    ck_tile::index_t batch_stride_dk = dk.stride(0);
    ck_tile::index_t stride_dk = dk.stride(1);
    ck_tile::index_t nhead_stride_dk = dk.stride(2);

    // dv_expanded: (batch_size, seqlen_k, nheads, hdim)
    ck_tile::index_t batch_stride_dv = dv.stride(0);
    ck_tile::index_t stride_dv = dv.stride(1);
    ck_tile::index_t nhead_stride_dv = dv.stride(2);

    // dq_acc: (split, batch_size, nheads, seqlen_q, hdim)
    ck_tile::index_t split_stride_dq_acc = dq_acc.stride(0);
    ck_tile::index_t batch_stride_dq_acc = dq_acc.stride(1);
    ck_tile::index_t stride_dq_acc = dq_acc.stride(3);
    ck_tile::index_t nhead_stride_dq_acc = dq_acc.stride(2);

    // bias: (batch_size, nheads, seqlen_q, seqlen_k)
    void *attn_bias_ptr = nullptr;
    ck_tile::index_t nhead_stride_bias = 0;
    ck_tile::index_t batch_stride_bias = 0;
    ck_tile::index_t stride_attn_bias = 0;
    if (attn_bias_.has_value()) {
        auto a_b = attn_bias_.value();
        CHECK_DEVICE(a_b);
        TORCH_CHECK(a_b.stride(-1) == 1, "Attention bias tensor must have contiguous last dimension");
        attn_bias_ptr = a_b.data_ptr();
        stride_attn_bias = a_b.stride(2);
        nhead_stride_bias = a_b.stride(1);
        batch_stride_bias = a_b.stride(0);
    }

    // dbias: (batch_size, nheads, seqlen_q, seqlen_k)
    void *dbias_ptr = nullptr;
    ck_tile::index_t stride_dbias = 0;
    ck_tile::index_t nhead_stride_dbias = 0;
    ck_tile::index_t batch_stride_dbias = 0;
    if(bias_requires_grad) {
        // If bias_requires_grad is true, grad_bias is guaranteed to have a value via line 270
        //grad_bias
        auto dbias = grad_bias.value();
        dbias_ptr = dbias.data_ptr();
        stride_dbias = dbias.stride(2);
        nhead_stride_dbias = dbias.stride(1);
        batch_stride_dbias = dbias.stride(0);
    }

    float p_undrop = 1.0 - p_dropout;

    return fmha_bwd_args{q.data_ptr(),
                         k.data_ptr(),
                         v.data_ptr(),
                         attn_bias_ptr,              // bias
                         out.data_ptr(),
                         softmax_lse.data_ptr(),
                         dout.data_ptr(),
                         d.data_ptr(),
                         nullptr,                    // rand_val
                         dq.data_ptr(),
                         dk.data_ptr(),
                         dv.data_ptr(),
                         dbias_ptr,                 // dbias
                         dq_acc.data_ptr(),         // dq_acc
                         nullptr,                   // seqstart_q
                         nullptr,                   // seqstart_k
                         nullptr,                   // seqlen_k_ptr
                         seqlen_q,
                         seqlen_k,
                         b,
                         seqlen_q,                  // max_seqlen_q
                         seqlen_k,                  // max_seqlen_k
                         hdim,                      // hdim_q
                         hdim,                      // hdim_v
                         h,                         // nhead
                         h_k,                       // nhead_k
                         softmax_scale,
                         stride_q,
                         stride_k,
                         stride_v,
                         stride_attn_bias,
                         stride_o,
                         0,                         // stride_randval
                         stride_do,
                         stride_dq_acc,
                         stride_dq,
                         stride_dk,
                         stride_dv,
                         stride_dbias,               // stride_dbias
                         nhead_stride_q,
                         nhead_stride_k,
                         nhead_stride_v,
                         nhead_stride_bias,          // nhead_stride_bias
                         nhead_stride_o,
                         0,                          // nhead_stride_randval
                         nhead_stride_do,
                         nhead_stride_lse,
                         nhead_stride_dq_acc,
                         nhead_stride_dq,
                         nhead_stride_dk,
                         nhead_stride_dv,
                         nhead_stride_dbias,         // nhead_stride_dbias
                         batch_stride_q,
                         batch_stride_k,
                         batch_stride_v,
                         batch_stride_bias,          // batch_stride_bias
                         batch_stride_o,
                         0,                          // batch_stride_randval
                         batch_stride_do,
                         batch_stride_lse,
                         batch_stride_dq_acc,
                         batch_stride_dq,
                         batch_stride_dk,
                         batch_stride_dv,
                         batch_stride_dbias,         // batch_stride_dbias
                         split_stride_dq_acc,
                         mask.left,
                         mask.right,
                         static_cast<ck_tile::index_t>(mask.type),
                         p_dropout,
                         p_undrop,
                         drop_seed_offset};
}
std::tuple<at::Tensor, at::Tensor, at::Tensor, at::Tensor, at::Tensor>
mha_bwd_ck(const at::Tensor &dout,                   // batch_size x seqlen_q x num_heads, x head_size_og
           const at::Tensor &q,                      // batch_size x seqlen_q x num_heads x head_size
           const at::Tensor &k,                      // batch_size x seqlen_k x num_heads_k x head_size
           const at::Tensor &v,                      // batch_size x seqlen_k x num_heads_k x head_size
           const at::Tensor &out,                    // batch_size x seqlen_q x num_heads x head_size
           const at::Tensor &softmax_lse,            // b x h x seqlen_q
           std::optional<at::Tensor> &dq_,           // batch_size x seqlen_q x num_heads x head_size
           std::optional<at::Tensor> &dk_,           // batch_size x seqlen_k x num_heads_k x head_size
           std::optional<at::Tensor> &dv_,           // batch_size x seqlen_k x num_heads_k x head_size
           std::optional<at::Tensor> &attn_bias_,    // num_heads or batch_size x num_heads
           bool bias_requires_grad,
           std::optional<at::Tensor> &grad_bias,
           const float p_dropout,                    // probability to drop
           const float softmax_scale,
           const bool is_causal,
           int window_size_left,
           int window_size_right,
           const bool deterministic,
           const at::Tensor philox_seed,
           const at::Tensor philox_offset)
{
#ifdef FLASHATTENTION_DISABLE_BACKWARD
    TORCH_CHECK(false, "This flash attention build does not support backward.");
#endif
    if (is_causal) { window_size_right = 0; }

    bool is_dropout = p_dropout > 0.0;
    auto stream = at::cuda::getCurrentHIPStream().stream();

    auto q_dtype = q.dtype();
    TORCH_CHECK(q_dtype == at::kHalf || q_dtype == at::kBFloat16,
                "FlashAttention only support fp16 and bf16 data type");

    TORCH_CHECK(k.dtype() == q_dtype, "query and key must have the same dtype");
    TORCH_CHECK(v.dtype() == q_dtype, "query and value must have the same dtype");
    TORCH_CHECK(out.dtype() == q_dtype, "query and out must have the same dtype");
    TORCH_CHECK(dout.dtype() == q_dtype, "query and dout must have the same dtype");

    std::string q_dtype_str = q_dtype == at::kHalf ? "fp16" : "bf16";

    CHECK_DEVICE(q); CHECK_DEVICE(k); CHECK_DEVICE(v);
    CHECK_DEVICE(out); CHECK_DEVICE(dout); CHECK_DEVICE(softmax_lse);

    TORCH_CHECK(q.stride(-1) == 1, "Input tensor must have contiguous last dimension");
    TORCH_CHECK(k.stride(-1) == 1, "Input tensor must have contiguous last dimension");
    TORCH_CHECK(v.stride(-1) == 1, "Input tensor must have contiguous last dimension");
    TORCH_CHECK(out.stride(-1) == 1, "out tensor must have contiguous last dimension");
    TORCH_CHECK(dout.stride(-1) == 1, "dout tensor must have contiguous last dimension");

    TORCH_CHECK((bias_requires_grad && grad_bias.has_value()) || (!bias_requires_grad),
            "If bias_requires_grad is set, grad_bias must have a value");

    const auto sizes = q.sizes();

    const int batch_size = sizes[0];
    const int seqlen_q = sizes[1];
    const int num_heads = sizes[2];
    const int head_size_og = dout.size(3);  // unpadded hdim
    const int head_size_8x = sizes[3];
    const int seqlen_k = k.size(1);
    const int num_heads_k = k.size(2);
    TORCH_CHECK(batch_size > 0, "batch size must be positive");
    TORCH_CHECK(head_size_8x % 8 == 0, "head_size_8x should be a multiple of 8");
    TORCH_CHECK(head_size_8x <= 256, "CK FlashAttention backward only supports head dimension at most 256");
    TORCH_CHECK(num_heads % num_heads_k == 0, "Number of heads in key/value must divide number of heads in query");

    auto round_multiple = [](int x, int m) { return (x + m - 1) / m * m; };
    TORCH_CHECK(head_size_8x == round_multiple(head_size_og, 8), "head_size_8x must be head_size_og rounded to a multiple of 8");

    if (window_size_left >= seqlen_k) { window_size_left = -1; }
    if (window_size_right >= seqlen_k) { window_size_right = -1; }

    mask_info mask;
    if (is_causal) {
        std::string mask_identify = "b:" + std::to_string(window_size_left) + "," + "0";
        mask = mask_info::decode(mask_identify, seqlen_q, seqlen_k); // casual
    }
    else if (window_size_left == -1 && window_size_right == -1) {
        mask = mask_info::decode("0", seqlen_q, seqlen_k); // no mask
    }
    else {
        // Local is the more general case where window_size_right >= 0 or window_size_left >= 0.
        std::string mask_identify = "b:" + std::to_string(window_size_left) + "," + std::to_string(window_size_right);
        mask = mask_info::decode(mask_identify, seqlen_q, seqlen_k); // local
    }

    // q, k, v, out had been padded in mha_fwd
    // dq_, dk_, dv_ are also padded tensor
    CHECK_SHAPE(q, batch_size, seqlen_q, num_heads, head_size_8x);
    CHECK_SHAPE(k, batch_size, seqlen_k, num_heads_k, head_size_8x);
    CHECK_SHAPE(v, batch_size, seqlen_k, num_heads_k, head_size_8x);
    CHECK_SHAPE(out, batch_size, seqlen_q, num_heads, head_size_8x);
    CHECK_SHAPE(dout, batch_size, seqlen_q, num_heads, head_size_og);

    at::Tensor dq, dk, dv;
    if (dq_.has_value()) {
        dq = dq_.value();
        TORCH_CHECK(dq.dtype() == q_dtype, "dq must have the same dtype as q");
        CHECK_DEVICE(dq);
        TORCH_CHECK(dq.stride(-1) == 1, "dq must have contiguous last dimension");
        CHECK_SHAPE(dq, batch_size, seqlen_q, num_heads, head_size_8x);
    } else {
        dq = at::empty_like(q);
    }
    if (dk_.has_value()) {
    dk = dk_.value();
    TORCH_CHECK(dk.dtype() == q_dtype, "dk must have the same dtype as q");
    CHECK_DEVICE(dk);
    TORCH_CHECK(dk.stride(-1) == 1, "dk must have contiguous last dimension");
    CHECK_SHAPE(dk, batch_size, seqlen_k, num_heads_k, head_size_8x);
    } else {
        dk = at::empty_like(k);
    }
    if (dv_.has_value()) {
        dv = dv_.value();
        TORCH_CHECK(dv.dtype() == q_dtype, "dv must have the same dtype as q");
        CHECK_DEVICE(dv);
        TORCH_CHECK(dv.stride(-1) == 1, "dv must have contiguous last dimension");
        CHECK_SHAPE(dv, batch_size, seqlen_k, num_heads_k, head_size_8x);
    } else {
        dv = at::empty_like(v);
    }

    at::Tensor dout_padded;
    if (head_size_og % 8 != 0) {
        dout_padded = at::pad(dout, {0, 8 - head_size_og % 8});
    } else {
        dout_padded = dout;
    }

    // Cast to char to avoid compiler warning about narrowing
    at::hip::HIPGuardMasqueradingAsCUDA device_guard{(char)q.get_device()};

    auto opts = q.options();
    auto softmax_d = at::empty({batch_size, num_heads, seqlen_q}, opts.dtype(at::kFloat));
    at::Tensor dq_accum;

    if (!deterministic) {
        dq_accum = at::zeros({1, batch_size, num_heads, seqlen_q, head_size_8x}, opts.dtype(at::kFloat));
    } else {
        const ck_tile::index_t kN0 = head_size_8x <= 128 ? 128 : 64;
        const ck_tile::index_t nsplits = ck_tile::integer_divide_ceil(seqlen_k, kN0);
        dq_accum = at::zeros({nsplits, batch_size, num_heads, seqlen_q, head_size_8x}, opts.dtype(at::kFloat));
    }

    at::Tensor dk_expanded, dv_expanded;
    if (num_heads_k != num_heads) {  // MQA / GQA
        dk_expanded = at::empty({batch_size, seqlen_k, num_heads, head_size_8x}, opts);
        dv_expanded = at::empty({batch_size, seqlen_k, num_heads, head_size_8x}, opts);
    } else {
        dk_expanded = dk;
        dv_expanded = dv;
    }

    uint64_t drop_seed = 1, drop_offset = 0;
    drop_seed = *philox_seed.data_ptr<int64_t>();
    drop_offset = *philox_offset.data_ptr<int64_t>();
    auto drop_seed_offset = std::make_pair(&drop_seed, &drop_offset);


    if (seqlen_q > 0) {
        ck_tile::stream_config stream_config{stream};
        dq.zero_(); // ck use atomic operation on dq

        auto args =
            get_ck_fmha_bwd_args(
                mask,
                batch_size,
                seqlen_q,
                seqlen_k,
                num_heads,
                num_heads_k,
                head_size_8x,
                q,
                k,
                v,
                attn_bias_,
                bias_requires_grad,
                grad_bias,
                out,
                softmax_lse,
                dout_padded,
                dq_accum,
                softmax_d,
                dq,
                dk_expanded,
                dv_expanded,
                softmax_scale,
                p_dropout,
                drop_seed_offset);

        float t = aiter::mha_bwd(args,
                                 stream_config,
                                 q_dtype_str,
                                 false,             // is_group_mode
                                 mask.type,
                                 attn_bias_.has_value() ? bias_enum::elementwise_bias : bias_enum::no_bias,
                                 bias_requires_grad,
                                 false,             // is_store_randval
                                 deterministic,
                                 true,              // use_ext_asm
                                 true,             // is_v3_atomic_fp32
                                 1);                // how_v3_bf16_cvt




        TORCH_CHECK(t >= 0, "invalid argument for fmha_bwd");
    } else {
        // If seqlen_q == 0, then we have an empty tensor. We need to set the output to 0.
        dk_expanded.zero_();
        dv_expanded.zero_();
        softmax_d.zero_();
    }

    // For MQA/GQA we need to sum dK and dV across the groups
    if (num_heads_k != num_heads) {
        at::sum_out(dk, at::reshape(dk_expanded, {batch_size, seqlen_k, num_heads_k, num_heads / num_heads_k, head_size_8x}), {3});
        at::sum_out(dv, at::reshape(dv_expanded, {batch_size, seqlen_k, num_heads_k, num_heads / num_heads_k, head_size_8x}), {3});
    }
    if (head_size_og % 8 != 0) {
        dq = dq.index({"...", at::indexing::Slice(at::indexing::None, head_size_og)});
        dk = dk.index({"...", at::indexing::Slice(at::indexing::None, head_size_og)});
        dv = dv.index({"...", at::indexing::Slice(at::indexing::None, head_size_og)});
    }

    at::Tensor dbias;
    if(bias_requires_grad) {
        dbias = grad_bias.value();
    } else {
        dbias = at::empty({batch_size, num_heads, seqlen_q, seqlen_k}, q.options());
    }


    return { dq, dk, dv, softmax_d, dbias };
}
} // namespace pytorch_flash
