package android.graphics;

import java.util.Arrays;

/** Android's row-major 4 by 5 transform of unpremultiplied RGBA channels. */
public class ColorMatrix {
    private final float[] values = new float[20];

    public ColorMatrix() { reset(); }
    public ColorMatrix(float[] src) { set(src); }
    public ColorMatrix(ColorMatrix src) { set(src); }
    public final float[] getArray() { return values; }
    public void reset() {
        Arrays.fill(values, 0);
        values[0] = values[6] = values[12] = values[18] = 1;
    }
    public void set(ColorMatrix src) { set(src.values); }
    public void set(float[] src) { System.arraycopy(src, 0, values, 0, 20); }
    public void setScale(float r, float g, float b, float a) {
        Arrays.fill(values, 0);
        values[0] = r; values[6] = g; values[12] = b; values[18] = a;
    }
    public void setRotate(int axis, float degrees) {
        reset();
        float cosine = (float) Math.cos(Math.toRadians(degrees));
        float sine = (float) Math.sin(Math.toRadians(degrees));
        switch (axis) {
            case 0 -> { values[6] = values[12] = cosine; values[7] = sine; values[11] = -sine; }
            case 1 -> { values[0] = values[12] = cosine; values[2] = -sine; values[10] = sine; }
            case 2 -> { values[0] = values[6] = cosine; values[1] = sine; values[5] = -sine; }
            default -> throw new RuntimeException("Invalid rotation axis " + axis);
        }
    }
    public void setConcat(ColorMatrix a, ColorMatrix b) {
        float[] out = new float[20];
        for (int row = 0; row < 4; row++) {
            int offset = row * 5;
            for (int column = 0; column < 5; column++) {
                float total = column == 4 ? a.values[offset + 4] : 0;
                for (int inner = 0; inner < 4; inner++) {
                    total += a.values[offset + inner] * b.values[inner * 5 + column];
                }
                out[offset + column] = total;
            }
        }
        set(out);
    }
    public void preConcat(ColorMatrix other) { setConcat(this, other); }
    public void postConcat(ColorMatrix other) { setConcat(other, this); }
    public void setSaturation(float saturation) {
        reset();
        float inverse = 1 - saturation;
        float r = .213f * inverse, g = .715f * inverse, b = .072f * inverse;
        values[0] = r + saturation; values[1] = g; values[2] = b;
        values[5] = r; values[6] = g + saturation; values[7] = b;
        values[10] = r; values[11] = g; values[12] = b + saturation;
    }
    public void setRGB2YUV() {
        reset();
        values[0] = .299f; values[1] = .587f; values[2] = .114f;
        values[5] = -.16874f; values[6] = -.33126f; values[7] = .5f;
        values[10] = .5f; values[11] = -.41869f; values[12] = -.08131f;
    }
    public void setYUV2RGB() {
        reset();
        values[2] = 1.402f;
        values[5] = 1; values[6] = -.34414f; values[7] = -.71414f;
        values[10] = 1; values[11] = 1.772f; values[12] = 0;
    }
    @Override public boolean equals(Object other) {
        if (!(other instanceof ColorMatrix matrix)) return false;
        for (int i = 0; i < 20; i++) if (values[i] != matrix.values[i]) return false;
        return true;
    }
    @Override public int hashCode() {
        int hash = 1;
        for (float value : values) hash = 31 * hash + Float.floatToIntBits(value == 0 ? 0 : value);
        return hash;
    }
}
