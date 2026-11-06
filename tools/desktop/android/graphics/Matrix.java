package android.graphics;

/** Android's row-major 3 by 3 point transform, without native Android calls. */
public class Matrix {
    public static final int MSCALE_X = 0;
    public static final int MSKEW_X = 1;
    public static final int MTRANS_X = 2;
    public static final int MSKEW_Y = 3;
    public static final int MSCALE_Y = 4;
    public static final int MTRANS_Y = 5;
    public static final int MPERSP_0 = 6;
    public static final int MPERSP_1 = 7;
    public static final int MPERSP_2 = 8;

    public enum ScaleToFit { FILL, START, CENTER, END }

    private final float[] values = new float[9];

    public Matrix() { reset(); }
    public Matrix(Matrix source) { set(source); }

    public boolean isIdentity() {
        return values[0] == 1 && values[1] == 0 && values[2] == 0
                && values[3] == 0 && values[4] == 1 && values[5] == 0
                && values[6] == 0 && values[7] == 0 && values[8] == 1;
    }

    public boolean isAffine() {
        return values[6] == 0 && values[7] == 0 && values[8] == 1;
    }

    public boolean rectStaysRect() {
        return isAffine() && ((values[1] == 0 && values[3] == 0 && values[0] != 0 && values[4] != 0)
                || (values[0] == 0 && values[4] == 0 && values[1] != 0 && values[3] != 0));
    }

    public void set(Matrix source) {
        if (source == null) reset();
        else System.arraycopy(source.values, 0, values, 0, 9);
    }

    @Override public boolean equals(Object other) {
        if (!(other instanceof Matrix)) return false;
        float[] that = ((Matrix) other).values;
        for (int i = 0; i < 9; i++) if (values[i] != that[i]) return false;
        return true;
    }

    @Override public int hashCode() { return 44; }

    public void reset() {
        java.util.Arrays.fill(values, 0);
        values[0] = values[4] = values[8] = 1;
    }

    public void setTranslate(float dx, float dy) {
        reset(); values[2] = dx; values[5] = dy;
    }

    public void setScale(float sx, float sy, float px, float py) {
        setScale(sx, sy); values[2] = px - sx * px; values[5] = py - sy * py;
    }

    public void setScale(float sx, float sy) {
        reset(); values[0] = sx; values[4] = sy;
    }

    public void setRotate(float degrees, float px, float py) {
        double radians = Math.toRadians(degrees);
        setSinCos(snapTrig(Math.sin(radians)), snapTrig(Math.cos(radians)), px, py);
    }

    public void setRotate(float degrees) { setRotate(degrees, 0, 0); }

    private static float snapTrig(double value) {
        return Math.abs(value) < 1e-15 ? 0 : (float) value;
    }

    public void setSinCos(float sin, float cos, float px, float py) {
        setSinCos(sin, cos);
        values[2] = px - cos * px + sin * py;
        values[5] = py - sin * px - cos * py;
    }

    public void setSinCos(float sin, float cos) {
        reset(); values[0] = values[4] = cos; values[1] = -sin; values[3] = sin;
    }

    public void setSkew(float kx, float ky, float px, float py) {
        setSkew(kx, ky); values[2] = -kx * py; values[5] = -ky * px;
    }

    public void setSkew(float kx, float ky) {
        reset(); values[1] = kx; values[3] = ky;
    }

    public boolean setConcat(Matrix first, Matrix second) {
        float[] result = new float[9];
        for (int row = 0; row < 3; row++) {
            for (int col = 0; col < 3; col++) {
                double sum = 0;
                for (int k = 0; k < 3; k++) sum += (double) first.values[row * 3 + k] * second.values[k * 3 + col];
                result[row * 3 + col] = (float) sum;
            }
        }
        System.arraycopy(result, 0, values, 0, 9);
        return true;
    }

    public boolean preTranslate(float dx, float dy) {
        Matrix m = new Matrix(); m.setTranslate(dx, dy); return preConcat(m);
    }
    public boolean preScale(float sx, float sy, float px, float py) {
        Matrix m = new Matrix(); m.setScale(sx, sy, px, py); return preConcat(m);
    }
    public boolean preScale(float sx, float sy) { return preScale(sx, sy, 0, 0); }
    public boolean preRotate(float degrees, float px, float py) {
        Matrix m = new Matrix(); m.setRotate(degrees, px, py); return preConcat(m);
    }
    public boolean preRotate(float degrees) { return preRotate(degrees, 0, 0); }
    public boolean preSkew(float kx, float ky, float px, float py) {
        Matrix m = new Matrix(); m.setSkew(kx, ky, px, py); return preConcat(m);
    }
    public boolean preSkew(float kx, float ky) { return preSkew(kx, ky, 0, 0); }
    public boolean preConcat(Matrix other) { return setConcat(this, other); }
    public boolean postTranslate(float dx, float dy) {
        Matrix m = new Matrix(); m.setTranslate(dx, dy); return postConcat(m);
    }
    public boolean postScale(float sx, float sy, float px, float py) {
        Matrix m = new Matrix(); m.setScale(sx, sy, px, py); return postConcat(m);
    }
    public boolean postScale(float sx, float sy) { return postScale(sx, sy, 0, 0); }
    public boolean postRotate(float degrees, float px, float py) {
        Matrix m = new Matrix(); m.setRotate(degrees, px, py); return postConcat(m);
    }
    public boolean postRotate(float degrees) { return postRotate(degrees, 0, 0); }
    public boolean postSkew(float kx, float ky, float px, float py) {
        Matrix m = new Matrix(); m.setSkew(kx, ky, px, py); return postConcat(m);
    }
    public boolean postSkew(float kx, float ky) { return postSkew(kx, ky, 0, 0); }
    public boolean postConcat(Matrix other) { return setConcat(other, this); }

    public boolean setRectToRect(RectF source, RectF destination, ScaleToFit mode) {
        if (mode == null) throw new NullPointerException("mode");
        float sw = source.right - source.left, sh = source.bottom - source.top;
        if (sw <= 0 || sh <= 0) { reset(); return false; }
        float dw = destination.right - destination.left, dh = destination.bottom - destination.top;
        if (dw <= 0 || dh <= 0) { setScale(0, 0); return true; }
        float sx = dw / sw, sy = dh / sh;
        float extraX = 0, extraY = 0;
        if (mode != ScaleToFit.FILL) {
            sx = sy = Math.min(sx, sy);
            float alignment = mode == ScaleToFit.START ? 0 : mode == ScaleToFit.CENTER ? 0.5f : 1;
            extraX = (dw - sw * sx) * alignment;
            extraY = (dh - sh * sy) * alignment;
        }
        setScale(sx, sy);
        values[2] = destination.left - source.left * sx + extraX;
        values[5] = destination.top - source.top * sy + extraY;
        return true;
    }

    public boolean setPolyToPoly(float[] source, int sourceIndex, float[] destination,
            int destinationIndex, int pointCount) {
        if (pointCount < 0 || pointCount > 4) throw new IllegalArgumentException("pointCount must be 0..4");
        checkRange(source, sourceIndex, pointCount);
        checkRange(destination, destinationIndex, pointCount);
        if (pointCount == 0) { reset(); return true; }
        double sx = source[sourceIndex], sy = source[sourceIndex + 1];
        double dx = destination[destinationIndex], dy = destination[destinationIndex + 1];
        if (pointCount == 1) { setTranslate((float) (dx - sx), (float) (dy - sy)); return true; }
        if (pointCount == 2) {
            double ux = source[sourceIndex + 2] - sx, uy = source[sourceIndex + 3] - sy;
            double vx = destination[destinationIndex + 2] - dx, vy = destination[destinationIndex + 3] - dy;
            double length = ux * ux + uy * uy;
            if (length == 0) return false;
            double a = (ux * vx + uy * vy) / length, b = (ux * vy - uy * vx) / length;
            setValues(new float[] {(float) a, (float) -b, (float) (dx - a * sx + b * sy),
                    (float) b, (float) a, (float) (dy - b * sx - a * sy), 0, 0, 1});
            return true;
        }
        int unknowns = pointCount == 3 ? 6 : 8;
        double[][] equations = new double[unknowns][unknowns + 1];
        for (int i = 0; i < pointCount; i++) {
            double x = source[sourceIndex + 2 * i], y = source[sourceIndex + 2 * i + 1];
            double u = destination[destinationIndex + 2 * i], v = destination[destinationIndex + 2 * i + 1];
            double[] first = equations[2 * i], second = equations[2 * i + 1];
            first[0] = second[3] = x; first[1] = second[4] = y; first[2] = second[5] = 1;
            if (unknowns == 8) { first[6] = -u * x; first[7] = -u * y; second[6] = -v * x; second[7] = -v * y; }
            first[unknowns] = u; second[unknowns] = v;
        }
        float[] candidate = new float[9];
        if (unknowns == 6) {
            double[] result = solve(equations);
            if (result == null) return false;
            for (int i = 0; i < unknowns; i++) candidate[i] = (float) result[i];
            candidate[8] = 1;
        } else {
            // A homography is homogeneous: a valid transform can have m[8] == 0.
            // Try each possible normalization instead of requiring m[8] == 1.
            double[][] homogeneous = new double[8][9];
            for (int row = 0; row < 8; row++) {
                System.arraycopy(equations[row], 0, homogeneous[row], 0, 8);
                homogeneous[row][8] = -equations[row][8];
            }
            boolean found = false;
            for (int fixed = 8; fixed >= 0 && !found; fixed--) {
                double[][] system = new double[8][9];
                for (int row = 0; row < 8; row++) {
                    int col = 0;
                    for (int k = 0; k < 9; k++) if (k != fixed) system[row][col++] = homogeneous[row][k];
                    system[row][8] = -homogeneous[row][fixed];
                }
                double[] result = solve(system);
                if (result == null) continue;
                int col = 0;
                for (int k = 0; k < 9; k++) candidate[k] = k == fixed ? 1 : (float) result[col++];
                found = true;
            }
            if (!found) return false;
        }
        for (float value : candidate) if (!Float.isFinite(value)) return false;
        setValues(candidate);
        return true;
    }

    private static double[] solve(double[][] rows) {
        int count = rows.length;
        for (int col = 0; col < count; col++) {
            int pivot = col;
            for (int row = col + 1; row < count; row++) if (Math.abs(rows[row][col]) > Math.abs(rows[pivot][col])) pivot = row;
            if (rows[pivot][col] == 0 || !Double.isFinite(rows[pivot][col])) return null;
            double[] swap = rows[col]; rows[col] = rows[pivot]; rows[pivot] = swap;
            double divisor = rows[col][col];
            for (int j = col; j <= count; j++) rows[col][j] /= divisor;
            for (int row = 0; row < count; row++) {
                if (row == col) continue;
                double factor = rows[row][col];
                for (int j = col; j <= count; j++) rows[row][j] -= factor * rows[col][j];
            }
        }
        double[] result = new double[count];
        for (int i = 0; i < count; i++) { result[i] = rows[i][count]; if (!Double.isFinite(result[i])) return null; }
        return result;
    }

    public boolean invert(Matrix inverse) {
        double a = values[0], b = values[1], c = values[2], d = values[3], e = values[4];
        double f = values[5], g = values[6], h = values[7], i = values[8];
        double determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
        if (determinant == 0 || !Double.isFinite(determinant)) return false;
        float[] result = {(float) ((e * i - f * h) / determinant), (float) ((c * h - b * i) / determinant),
                (float) ((b * f - c * e) / determinant), (float) ((f * g - d * i) / determinant),
                (float) ((a * i - c * g) / determinant), (float) ((c * d - a * f) / determinant),
                (float) ((d * h - e * g) / determinant), (float) ((b * g - a * h) / determinant),
                (float) ((a * e - b * d) / determinant)};
        for (float value : result) if (!Float.isFinite(value)) return false;
        if (inverse != null) inverse.setValues(result);
        return true;
    }

    private static void checkRange(float[] points, int index, int count) {
        if (index < 0 || count < 0 || index > points.length || count > (points.length - index) / 2)
            throw new ArrayIndexOutOfBoundsException();
    }

    private void map(float[] destination, int destinationIndex, float[] source, int sourceIndex,
            int count, boolean vectors) {
        checkRange(source, sourceIndex, count); checkRange(destination, destinationIndex, count);
        float[] input = java.util.Arrays.copyOfRange(source, sourceIndex, sourceIndex + 2 * count);
        double originX = vectors ? values[2] / (double) values[8] : 0;
        double originY = vectors ? values[5] / (double) values[8] : 0;
        for (int p = 0; p < count; p++) {
            double x = input[2 * p], y = input[2 * p + 1];
            double denominator = values[6] * x + values[7] * y + values[8];
            if (vectors && values[6] == 0 && values[7] == 0) {
                destination[destinationIndex + 2 * p] = (float) ((values[0] * x + values[1] * y) / denominator);
                destination[destinationIndex + 2 * p + 1] = (float) ((values[3] * x + values[4] * y) / denominator);
                continue;
            }
            destination[destinationIndex + 2 * p] = (float) ((values[0] * x + values[1] * y + values[2]) / denominator - originX);
            destination[destinationIndex + 2 * p + 1] = (float) ((values[3] * x + values[4] * y + values[5]) / denominator - originY);
        }
    }

    public void mapPoints(float[] dst, int dstIndex, float[] src, int srcIndex, int count) { map(dst, dstIndex, src, srcIndex, count, false); }
    public void mapVectors(float[] dst, int dstIndex, float[] src, int srcIndex, int count) { map(dst, dstIndex, src, srcIndex, count, true); }
    public void mapPoints(float[] dst, float[] src) { checkLengths(dst, src); mapPoints(dst, 0, src, 0, dst.length / 2); }
    public void mapVectors(float[] dst, float[] src) { checkLengths(dst, src); mapVectors(dst, 0, src, 0, dst.length / 2); }
    public void mapPoints(float[] points) { mapPoints(points, 0, points, 0, points.length / 2); }
    public void mapVectors(float[] vectors) { mapVectors(vectors, 0, vectors, 0, vectors.length / 2); }
    private static void checkLengths(float[] dst, float[] src) {
        if (dst.length != src.length) throw new ArrayIndexOutOfBoundsException();
    }

    public boolean mapRect(RectF destination, RectF source) {
        float[] points = {source.left, source.top, source.right, source.top,
                source.right, source.bottom, source.left, source.bottom};
        mapPoints(points);
        float left = points[0], right = points[0], top = points[1], bottom = points[1];
        for (int p = 1; p < 4; p++) {
            left = Math.min(left, points[2 * p]); right = Math.max(right, points[2 * p]);
            top = Math.min(top, points[2 * p + 1]); bottom = Math.max(bottom, points[2 * p + 1]);
        }
        destination.left = left; destination.top = top; destination.right = right; destination.bottom = bottom;
        return rectStaysRect();
    }
    public boolean mapRect(RectF rect) { return mapRect(rect, rect); }
    public float mapRadius(float radius) {
        float[] vectors = {radius, 0, 0, radius}; mapVectors(vectors);
        return (float) Math.sqrt(Math.hypot(vectors[0], vectors[1]) * Math.hypot(vectors[2], vectors[3]));
    }
    public void getValues(float[] destination) {
        if (destination.length < 9) throw new ArrayIndexOutOfBoundsException();
        System.arraycopy(values, 0, destination, 0, 9);
    }
    public void setValues(float[] source) {
        if (source.length < 9) throw new ArrayIndexOutOfBoundsException();
        System.arraycopy(source, 0, values, 0, 9);
    }
    @Override public String toString() { return "Matrix{" + toShortString() + "}"; }
    public String toShortString() {
        return "[" + values[0] + ", " + values[1] + ", " + values[2] + "]["
                + values[3] + ", " + values[4] + ", " + values[5] + "]["
                + values[6] + ", " + values[7] + ", " + values[8] + "]";
    }
}
