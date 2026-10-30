"""Convert Google's MediaPipe iris model (Apache-2.0) to Core ML and check the conversion.

    pip install coremltools ai-edge-litert tflite numpy
    curl -LO https://storage.googleapis.com/mediapipe-assets/iris_landmark.tflite
    python tools/convert_iris.py iris_landmark.tflite Models/IrisLandmark.mlpackage

The model only uses 7 TFLite ops, so they are mapped to Core ML one by one. The same
layer list also runs in numpy and is compared against Google's runtime before saving.
"""
import sys

import coremltools as ct
import numpy as np
import tflite
from ai_edge_litert.interpreter import Interpreter
from coremltools.converters.mil import Builder as mb


def load_layers(path):
    """Return the model as (kind, input ids, output id, params) steps, weights in NCHW."""
    m = tflite.Model.GetRootAsModel(open(path, "rb").read(), 0)
    g = m.Subgraphs(0)
    names = {v: k for k, v in vars(tflite.BuiltinOperator).items() if not k.startswith("_")}

    def const(i):
        t = g.Tensors(i)
        dtype = np.float32 if t.Type() == tflite.TensorType.FLOAT32 else np.int32
        return np.frombuffer(m.Buffers(t.Buffer()).DataAsNumpy().tobytes(), dtype).reshape(t.ShapeAsNumpy())

    layers = []
    for i in range(g.OperatorsLength()):
        op = g.Operators(i)
        code = m.OperatorCodes(op.OpcodeIndex())
        kind = names[max(code.BuiltinCode(), code.DeprecatedBuiltinCode())]
        ins = [op.Inputs(j) for j in range(op.InputsLength())]
        o = op.BuiltinOptions()
        p = {}
        if kind in ("CONV_2D", "DEPTHWISE_CONV_2D"):
            opt = (tflite.Conv2DOptions if kind == "CONV_2D" else tflite.DepthwiseConv2DOptions)()
            opt.Init(o.Bytes, o.Pos)
            assert opt.FusedActivationFunction() == 0 and opt.DilationHFactor() == 1 and opt.StrideH() == opt.StrideW()
            w = const(ins[1])  # conv: O,H,W,I   depthwise: 1,H,W,C
            if kind == "DEPTHWISE_CONV_2D":
                assert opt.DepthMultiplier() == 1
            p = dict(
                w=w.transpose(0, 3, 1, 2) if kind == "CONV_2D" else w.transpose(3, 0, 1, 2),
                b=const(ins[2]),
                stride=opt.StrideH(),
                same=opt.Padding() == tflite.Padding.SAME,
                groups=1 if kind == "CONV_2D" else w.shape[3],
            )
            kind, ins = "CONV", ins[:1]
        elif kind == "PRELU":
            p, ins = dict(alpha=const(ins[1]).reshape(-1)), ins[:1]
        elif kind == "ADD":
            opt = tflite.AddOptions()
            opt.Init(o.Bytes, o.Pos)
            assert opt.FusedActivationFunction() == 0
        elif kind == "MAX_POOL_2D":
            opt = tflite.Pool2DOptions()
            opt.Init(o.Bytes, o.Pos)
            assert (opt.FilterHeight(), opt.FilterWidth(), opt.StrideH(), opt.StrideW()) == (2, 2, 2, 2)
            assert opt.Padding() == tflite.Padding.VALID and opt.FusedActivationFunction() == 0
        elif kind == "PAD":
            p, ins = dict(pad=const(ins[1])[[0, 3, 1, 2]].reshape(-1)), ins[:1]  # NHWC rows -> NCHW
        elif kind == "RESHAPE":
            assert tuple(g.Tensors(ins[0]).ShapeAsNumpy())[1:3] == (1, 1)  # NCHW and NHWC agree at 1x1
            ins = ins[:1]
        else:
            raise ValueError(f"unsupported op {kind}")
        layers.append((kind, ins, op.Outputs(0), p))

    outputs = {g.Tensors(g.Outputs(i)).Name().decode(): g.Outputs(i) for i in range(g.OutputsLength())}
    return layers, g.Inputs(0), outputs["output_iris"]


def run_numpy(layers, inp, out, x):
    v = {inp: x}
    for kind, ins, o, p in layers:
        a = v[ins[0]]
        if kind == "CONV":
            k, s = p["w"].shape[2], p["stride"]
            if p["same"]:  # TF SAME: the extra pixel goes at the end
                n = a.shape[2]
                t = max((-(-n // s) - 1) * s + k - n, 0)
                a = np.pad(a, ((0, 0), (0, 0), (t // 2, t - t // 2), (t // 2, t - t // 2)))
            win = np.lib.stride_tricks.sliding_window_view(a, (k, k), axis=(2, 3))[:, :, ::s, ::s]
            if p["groups"] == 1:
                a = np.einsum("nchwij,ocij->nohw", win, p["w"])
            else:
                a = np.einsum("nchwij,cij->nchw", win, p["w"][:, 0])
            a = a + p["b"][None, :, None, None]
        elif kind == "PRELU":
            a = np.where(a > 0, a, a * p["alpha"][None, :, None, None])
        elif kind == "ADD":
            a = a + v[ins[1]]
        elif kind == "MAX_POOL_2D":
            n, c, h, w = a.shape
            a = a[:, :, : h // 2 * 2, : w // 2 * 2].reshape(n, c, h // 2, 2, w // 2, 2).max(axis=(3, 5))
        elif kind == "PAD":
            a = np.pad(a, p["pad"].reshape(4, 2))
        elif kind == "RESHAPE":
            a = a.reshape(1, -1)
        v[o] = a
    return v[out]


def to_coreml(layers, inp, out):
    @mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 64, 64))], opset_version=ct.target.macOS13)
    def prog(image):
        v = {inp: image}
        for kind, ins, o, p in layers:
            a = v[ins[0]]
            if kind == "CONV":
                s = [p["stride"]] * 2
                a = mb.conv(x=a, weight=p["w"], bias=p["b"], strides=s, groups=p["groups"],
                            pad_type="same" if p["same"] else "valid")
            elif kind == "PRELU":
                a = mb.prelu(x=a, alpha=p["alpha"])
            elif kind == "ADD":
                a = mb.add(x=a, y=v[ins[1]])
            elif kind == "MAX_POOL_2D":
                a = mb.max_pool(x=a, kernel_sizes=[2, 2], strides=[2, 2], pad_type="valid")
            elif kind == "PAD":
                a = mb.pad(x=a, pad=p["pad"])
            elif kind == "RESHAPE":
                a = mb.reshape(x=a, shape=[1, -1])
            v[o] = a
        return mb.identity(x=v[out], name="iris")

    return ct.convert(
        prog,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 64, 64), scale=1 / 255, color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.macOS13,
    )


if __name__ == "__main__":
    src, dst = sys.argv[1:3]
    layers, inp, out = load_layers(src)

    x = np.random.default_rng(0).random((1, 64, 64, 3), dtype=np.float32)  # MediaPipe feeds [0,1] RGB
    it = Interpreter(model_path=src)
    it.allocate_tensors()
    it.set_tensor(it.get_input_details()[0]["index"], x)
    it.invoke()
    want = next(it.get_tensor(d["index"]) for d in it.get_output_details() if d["name"] == "output_iris")
    got = run_numpy(layers, inp, out, x.transpose(0, 3, 1, 2))
    err = np.abs(got - want).max()
    print(f"numpy vs Google runtime, max error {err:.2e} px")
    assert err < 1e-3

    model = to_coreml(layers, inp, out)
    model.short_description = "MediaPipe iris landmarks (Google, Apache-2.0). Output: 5 iris points (x,y,z) in 64px crop space."
    model.save(dst)
    print("saved", dst)
