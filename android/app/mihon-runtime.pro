# These entry points are called by APK DEX loaded after R8 has run. They have
# no static callers in the host, but their original names and descriptors are ABI.
-keep class eu.kanade.tachiyomi.** { *; }
-keep class dev.mihon.injekt.** { *; }
# Installed-release ABI acceptance initializes the real host through reflection.
-keep class io.github.hyperionhxh.triomi.MihonHost { public <init>(android.content.Context); }
-keep class uy.kohesive.injekt.** { *; }
# R8 full mode retains generic signatures only on kept subclasses too.
# The host's anonymous references live outside the Injekt package.
-keep class * extends uy.kohesive.injekt.api.TypeReference { *; }
-keep class * extends uy.kohesive.injekt.api.FullTypeReference { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class rx.** { *; }
-keep class org.jsoup.** { *; }
# External extension DEX builds its own settings and calls these constructors,
# setters and listener interfaces by their original names. AndroidX consumer
# rules preserve XML class names only; they do not preserve this source ABI.
-keep class androidx.preference.** { *; }
# zstd-kmp 0.4.0 ships no consumer rules. Its JNI initialization looks up both
# codec classes and fields by name, including compressor when only decoding.
# Removing it causes ART to abort, which cannot be caught as a request error.
-keep class com.squareup.zstd.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlin.** { *; }
-keepattributes Signature,InnerClasses,EnclosingMethod,RuntimeVisibleAnnotations,AnnotationDefault
