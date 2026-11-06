import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.ColorMatrix;
import android.graphics.ColorMatrixColorFilter;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Rect;
import java.awt.image.BufferedImage;

public final class DesktopGraphicsTest {
    private static void check(boolean condition, String name) {
        if (!condition) throw new AssertionError(name);
    }
    private static void near(float actual, float expected, String name) {
        check(Math.abs(actual - expected) < .002f, name + ": " + actual);
    }
    private static Bitmap bitmap(int width, int height) {
        return new Bitmap(new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB));
    }
    public static void main(String[] args) {
        ColorMatrix identity = new ColorMatrix();
        check(identity.equals(new ColorMatrix(identity.getArray())), "identity copy");
        ColorMatrix translate = new ColorMatrix();
        translate.getArray()[4] = 10;
        ColorMatrix scale = new ColorMatrix();
        scale.setScale(2, 3, 4, 1);
        translate.preConcat(scale);
        near(translate.getArray()[4], 10, "pre concat translation");
        translate.postConcat(scale);
        near(translate.getArray()[4], 20, "post concat translation");
        near(translate.getArray()[0], 4, "aliased concat");
        ColorMatrix gray = new ColorMatrix();
        gray.setSaturation(0);
        near(gray.getArray()[0], .213f, "gray red");
        near(gray.getArray()[6], .715f, "gray green");
        ColorMatrix rotation = new ColorMatrix();
        rotation.setRotate(0, 90);
        near(rotation.getArray()[7], 1, "rotate green");
        near(rotation.getArray()[11], -1, "rotate blue");
        ColorMatrix yuv = new ColorMatrix(); yuv.setRGB2YUV();
        ColorMatrix rgb = new ColorMatrix(); rgb.setYUV2RGB();
        rgb.preConcat(yuv);
        near(rgb.getArray()[0], 1, "YUV red roundtrip");
        near(rgb.getArray()[6], 1, "YUV green roundtrip");
        near(rgb.getArray()[12], 1, "YUV blue roundtrip");

        float[] inversion = {-1, 0, 0, 0, 255, 0, -1, 0, 0, 255,
                0, 0, -1, 0, 255, 0, 0, 0, 1, 0};
        ColorMatrix original = new ColorMatrix(inversion);
        ColorMatrixColorFilter filter = new ColorMatrixColorFilter(original);
        original.reset(); inversion[0] = 0;
        ColorMatrix snapshot = new ColorMatrix(); filter.getColorMatrix(snapshot);
        near(snapshot.getArray()[0], -1, "filter defensive copy");
        snapshot.reset(); filter.getColorMatrix(snapshot);
        near(snapshot.getArray()[0], -1, "filter getter defensive copy");
        Bitmap source = bitmap(2, 1);
        source.getImage().setRGB(0, 0, 0xffff0000);
        source.getImage().setRGB(1, 0, 0xff0000ff);
        Paint paint = new Paint(); paint.setColorFilter(filter);
        Matrix matrix = new Matrix();
        matrix.postScale(-1, 1, 1, .5f);
        matrix.postTranslate(1, 1);
        Bitmap destination = bitmap(4, 3);
        new Canvas(destination).drawBitmap(source, matrix, paint);
        check(destination.getImage().getRGB(1, 1) == 0xffffff00, "flipped inverted blue");
        check(destination.getImage().getRGB(2, 1) == 0xff00ffff, "flipped inverted red");
        check(source.getImage().getRGB(0, 0) == 0xffff0000, "source not mutated");
        check(destination.getImage().getRGB(0, 0) == 0, "outside untouched");
        new Canvas(destination).drawBitmap(source, new Rect(0, 0, 1, 1), new Rect(0, 0, 1, 1), paint);
        check(destination.getImage().getRGB(0, 0) == 0xff00ffff, "rect color filter");
        new Canvas(destination).drawBitmap(source, 0, 2, null);
        check(destination.getImage().getRGB(0, 2) == 0xffff0000, "unfiltered offset drawing");
        Paint alpha = new Paint(); alpha.setAlpha(128);
        Bitmap faded = bitmap(2, 1);
        new Canvas(faded).drawBitmap(source, 0, 0, alpha);
        check((faded.getImage().getRGB(0, 0) >>> 24) == 128, "paint alpha");
        float[] clamp = new ColorMatrix().getArray();
        clamp[4] = 1000; clamp[9] = -1000;
        paint.setColorFilter(new ColorMatrixColorFilter(clamp));
        new Canvas(destination).drawBitmap(source, 0, 0, paint);
        check(destination.getImage().getRGB(0, 0) == 0xffff0000, "channel clamping");
        System.out.println("Desktop graphics matrix/filter/pixel checks passed");
    }
}
