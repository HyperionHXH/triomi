package triomi.desktop;

import com.android.apksig.ApkVerifier;
import com.sun.nio.file.ExtendedOpenOption;
import java.io.OutputStream;
import java.io.PrintStream;
import java.io.StringReader;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.LinkOption;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.util.HexFormat;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilderFactory;
import net.dongliu.apk.parser.ApkFile;
import java.util.HashSet;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;
import org.xml.sax.InputSource;

/** Static APK authentication only. Never creates a class loader for APK code. */
public final class ApkInspector {
    private static final String ANDROID = "http://schemas.android.com/apk/res/android";
    private static final HexFormat HEX = HexFormat.of();

    private ApkInspector() {}

    public static void main(String[] args) {
        PrintStream output = System.out;
        // Library diagnostics must never escape as arbitrary APK metadata, paths,
        // or extra stdout lines. The protocol emits exactly one compact object.
        System.setOut(new PrintStream(OutputStream.nullOutputStream()));
        System.setErr(new PrintStream(OutputStream.nullOutputStream()));
        try {
            output.println(inspect(args));
        } catch (Throwable failure) {
            output.println("{\"ok\":false,\"signatureVerified\":false,\"error\":\"apk_rejected\"}");
            System.exit(1);
        }
    }

    private static String inspect(String[] args) throws Exception {
        require(args.length == 3 || args.length == 4);
        Path path = Path.of(args[0]);
        require(path.isAbsolute());
        require(args[1].matches("[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+"));
        long expectedCode = Long.parseLong(args[2]);
        require(expectedCode >= 0);
        // Windows sharing restrictions hold the exact file identity stable while
        // the verifier, manifest parser and SHA stream independently read it.
        // Unlike a byte-range lock, they do not block these read-only handles.
        try (FileChannel identity = FileChannel.open(path, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS, ExtendedOpenOption.NOSHARE_WRITE,
                ExtendedOpenOption.NOSHARE_DELETE)) {
            ApkVerifier.Result verified = new ApkVerifier.Builder(path.toFile())
                    .setMinCheckedPlatformVersion(26).build().verify();
            require(verified.isVerified());
            require(verified.getSignerCertificates().size() == 1);
            String signer = HEX.formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(verified.getSignerCertificates().get(0).getEncoded()));
            String manifest;
            try (ApkFile apk = new ApkFile(path.toFile())) {
                manifest = apk.getManifestXml();
            }
            Element root = parseManifest(manifest);
            require(root.getTagName().equals("manifest"));
            String packageName = root.getAttribute("package");
            long versionCode = number(root.getAttributeNS(ANDROID, "versionCode"));
            // Android's optional major code must not hide a different identity.
            String major = root.getAttributeNS(ANDROID, "versionCodeMajor");
            require(major.isEmpty() || number(major) == 0);
            String versionName = root.getAttributeNS(ANDROID, "versionName");
            require(packageName.equals(args[1]) && versionCode == expectedCode);
            require(versionName.matches("1\\.(?:4|6)\\.[0-9]+"));
            boolean extension = false;
            NodeList features = root.getElementsByTagName("uses-feature");
            for (int i = 0; i < features.getLength(); i++) {
                Element feature = (Element) features.item(i);
                if (feature.getParentNode() == root && feature.getAttributeNS(ANDROID, "name")
                        .equals("tachiyomi.extension")) extension = true;
            }
            require(extension);
            boolean nsfw = false;
            NodeList applications = root.getElementsByTagName("application");
            require(applications.getLength() == 1);
            Element application = (Element) applications.item(0);
            NodeList metadata = application.getElementsByTagName("meta-data");
            boolean seenNsfw = false;
            for (int i = 0; i < metadata.getLength(); i++) {
                Element entry = (Element) metadata.item(i);
                if (entry.getParentNode() != application || !entry.getAttributeNS(ANDROID, "name")
                        .equals("tachiyomi.extension.nsfw")) continue;
                require(!seenNsfw);
                seenNsfw = true;
                String value = entry.getAttributeNS(ANDROID, "value");
                require(value.equals("0") || value.equals("1") ||
                        value.equals("false") || value.equals("true"));
                nsfw = value.equals("1") || value.equals("true");
            }
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            ByteBuffer buffer = ByteBuffer.allocate(64 * 1024);
            while (identity.read(buffer) != -1) {
                buffer.flip();
                digest.update(buffer);
                buffer.clear();
            }
            String jarMetadata = args.length == 4
                    ? inspectJar(Path.of(args[3]), packageName, versionCode, versionName, nsfw) : "";
            return "{\"ok\":true,\"signatureVerified\":true,\"packageName\":" + quote(packageName)
                    + ",\"versionCode\":" + versionCode + ",\"versionName\":" + quote(versionName)
                    + ",\"signerSha256\":" + quote(signer)
                    + ",\"sha256\":" + quote(HEX.formatHex(digest.digest()))
                    + ",\"nsfw\":" + nsfw + jarMetadata + "}";
        }
    }

    private static String inspectJar(Path path, String packageName, long versionCode,
            String versionName, boolean nsfw) throws Exception {
        require(path.isAbsolute());
        try (FileChannel identity = FileChannel.open(path, StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS, ExtendedOpenOption.NOSHARE_WRITE,
                ExtendedOpenOption.NOSHARE_DELETE);
                JarFile jar = new JarFile(path.toFile(), false)) {
            HashSet<String> names = new HashSet<>();
            boolean hasClass = false;
            JarEntry manifest = null;
            var entries = jar.entries();
            while (entries.hasMoreElements()) {
                JarEntry entry = entries.nextElement();
                String name = entry.getName();
                require(!name.isEmpty() && !name.startsWith("/") && !name.contains("\\")
                        && !name.contains(":") && name.indexOf('\0') < 0 && names.add(name));
                String[] parts = name.split("/", -1);
                for (int i = 0; i < parts.length; i++) {
                    require(!parts[i].equals(".") && !parts[i].equals("..")
                            && (!parts[i].isEmpty() || (entry.isDirectory() && i == parts.length - 1)));
                }
                if (!entry.isDirectory() && name.endsWith(".class")) hasClass = true;
                if (name.equals("AndroidManifest.xml")) manifest = entry;
            }
            require(hasClass && manifest != null && manifest.getSize() >= 0
                    && manifest.getSize() <= 1024 * 1024);
            byte[] bytes;
            try (InputStream source = jar.getInputStream(manifest)) {
                bytes = source.readNBytes(1024 * 1024 + 1);
            }
            require(bytes.length <= 1024 * 1024 && bytes.length == manifest.getSize());
            Element root = parseManifest(new String(bytes, StandardCharsets.UTF_8));
            require(root.getTagName().equals("manifest")
                    && root.getAttribute("package").equals(packageName)
                    && number(root.getAttributeNS(ANDROID, "versionCode")) == versionCode
                    && root.getAttributeNS(ANDROID, "versionName").equals(versionName));
            String major = root.getAttributeNS(ANDROID, "versionCodeMajor");
            require(major.isEmpty() || number(major) == 0);
            boolean extension = false;
            NodeList features = root.getElementsByTagName("uses-feature");
            for (int i = 0; i < features.getLength(); i++) {
                Element entry = (Element) features.item(i);
                if (entry.getParentNode() == root && entry.getAttributeNS(ANDROID, "name")
                        .equals("tachiyomi.extension")) extension = true;
            }
            require(extension);
            NodeList applications = root.getElementsByTagName("application");
            require(applications.getLength() == 1);
            Element application = (Element) applications.item(0);
            NodeList metadata = application.getElementsByTagName("meta-data");
            boolean jarNsfw = false;
            boolean seenNsfw = false;
            for (int i = 0; i < metadata.getLength(); i++) {
                Element entry = (Element) metadata.item(i);
                if (entry.getParentNode() != application) continue;
                String name = entry.getAttributeNS(ANDROID, "name");
                String value = entry.getAttributeNS(ANDROID, "value");
                if (name.equals("tachiyomix.extensionLib")) {
                    require(value.equals(versionName.substring(0, versionName.lastIndexOf('.'))));
                }
                if (!name.equals("tachiyomi.extension.nsfw")) continue;
                require(!seenNsfw);
                seenNsfw = true;
                require(value.equals("0") || value.equals("1")
                        || value.equals("false") || value.equals("true"));
                jarNsfw = value.equals("1") || value.equals("true");
            }
            require(jarNsfw == nsfw);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            ByteBuffer buffer = ByteBuffer.allocate(64 * 1024);
            while (identity.read(buffer) != -1) {
                buffer.flip();
                digest.update(buffer);
                buffer.clear();
            }
            // This hash is a separate JAR identity, not covered by the APK signer.
            return ",\"jarSha256\":" + quote(HEX.formatHex(digest.digest()));
        }
    }

    private static Element parseManifest(String xml) throws Exception {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_DTD, "");
        factory.setAttribute(XMLConstants.ACCESS_EXTERNAL_SCHEMA, "");
        factory.setXIncludeAware(false);
        factory.setExpandEntityReferences(false);
        return factory.newDocumentBuilder().parse(new InputSource(new StringReader(xml)))
                .getDocumentElement();
    }

    private static long number(String value) {
        return value.startsWith("0x") || value.startsWith("0X")
                ? Long.parseLong(value.substring(2), 16) : Long.parseLong(value);
    }

    private static void require(boolean accepted) {
        if (!accepted) throw new IllegalArgumentException();
    }

    private static String quote(String text) {
        StringBuilder result = new StringBuilder(text.length() + 2).append('"');
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (ch == '"' || ch == '\\') result.append('\\').append(ch);
            else if (ch < 0x20) {
                result.append("\\u");
                for (int shift = 12; shift >= 0; shift -= 4) {
                    result.append("0123456789abcdef".charAt((ch >>> shift) & 15));
                }
            } else result.append(ch);
        }
        return result.append('"').toString();
    }
}
