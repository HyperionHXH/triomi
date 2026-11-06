package android.graphics;

/** Stores a snapshot, matching Android's immutable filter construction. */
public class ColorMatrixColorFilter extends ColorFilter {
    private final ColorMatrix matrix;

    public ColorMatrixColorFilter(ColorMatrix src) { matrix = new ColorMatrix(src); }
    public ColorMatrixColorFilter(float[] src) { matrix = new ColorMatrix(src); }
    public void getColorMatrix(ColorMatrix destination) { destination.set(matrix); }

    int filter(int argb) {
        float[] m = matrix.getArray();
        int r = (argb >>> 16) & 255, g = (argb >>> 8) & 255, b = argb & 255, a = argb >>> 24;
        int red = channel(m, 0, r, g, b, a);
        int green = channel(m, 5, r, g, b, a);
        int blue = channel(m, 10, r, g, b, a);
        int alpha = channel(m, 15, r, g, b, a);
        return alpha << 24 | red << 16 | green << 8 | blue;
    }
    private static int channel(float[] m, int i, int r, int g, int b, int a) {
        return Math.max(0, Math.min(255, Math.round(m[i] * r + m[i + 1] * g
                + m[i + 2] * b + m[i + 3] * a + m[i + 4])));
    }
}
