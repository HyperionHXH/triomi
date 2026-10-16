import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is explicit and fail-closed. The acceptance flag is only
// for updating existing debug-signed test devices without deleting their data.
val acceptanceSigning = providers.gradleProperty("triomiAcceptanceSigning").orNull == "true"
val signingPath = providers.environmentVariable("TRIOMI_SIGNING_PROPERTIES").orNull
val releaseSigning = Properties()
if (signingPath != null) {
    val signingFile = file(signingPath)
    if (!signingFile.isFile) throw GradleException("Release signing properties unavailable")
    signingFile.inputStream().use { releaseSigning.load(it) }
}
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
if (releaseRequested && !acceptanceSigning &&
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword").any {
        releaseSigning.getProperty(it).isNullOrBlank()
    }) {
    throw GradleException("Release signing required: set TRIOMI_SIGNING_PROPERTIES; debug acceptance requires explicit triomiAcceptanceSigning=true")
}

dependencies {
    implementation("com.android.tools.build:apksig:8.13.0")
    implementation("androidx.webkit:webkit:1.12.1")
    // Pinned Media3 modules: one native decoder for files, HLS, subtitles/session.
    implementation("androidx.media3:media3-exoplayer:1.9.4")
    implementation("androidx.media3:media3-exoplayer-hls:1.9.4")
    implementation("androidx.media3:media3-ui:1.9.4")
    implementation("androidx.media3:media3-session:1.9.4")
    implementation("androidx.preference:preference-ktx:1.2.1")
    // Match flutter_secure_storage's cipher format for durable PIN commits.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // Mihon 1.6 extensions are compiled against the OkHttp 5 ABI (including
    // the Duration-mangled CacheControl builder methods).
    implementation("com.squareup.okhttp3:okhttp:5.3.2")
    implementation("com.squareup.okhttp3:okhttp-brotli:5.3.2")
    implementation("com.squareup.okhttp3:okhttp-zstd:5.3.2")
    implementation("com.squareup.okio:okio:3.15.0")
    implementation("io.reactivex:rxjava:1.3.8")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.1")
    // Komikku/Mihon source-api 1.6 is built against the current
    // serialization runtime; generated serializers use its extended ABI.
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-jvm:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-core-jvm:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-okio-jvm:1.11.0")
    implementation("org.jsoup:jsoup:1.22.2")
    implementation("com.github.mihonapp:injekt:91edab2317")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    // Flutter integration_test exports old test libraries into the app runtime.
    // Align them so AGP's consistent test resolution supports Android 12+.
    constraints {
        implementation("androidx.test:runner:1.6.2")
        implementation("androidx.test:core:1.6.1")
    }
}

android {
    namespace = "io.github.hyperionhxh.triomi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.hyperionhxh.triomi"
        testInstrumentationRunner = if (providers.gradleProperty("triomi.releaseAbiRunner").orNull == "true")
            "io.github.hyperionhxh.triomi.ReleaseAbiInstrumentation"
        else "androidx.test.runner.AndroidJUnitRunner"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigning.isNotEmpty()) {
            create("production") {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (acceptanceSigning) signingConfigs.getByName("debug")
                else signingConfigs.findByName("production")
            proguardFiles("mihon-runtime.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
