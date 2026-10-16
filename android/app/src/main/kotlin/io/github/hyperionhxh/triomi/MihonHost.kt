package io.github.hyperionhxh.triomi

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.app.Application
import com.android.apksig.ApkVerifier
import dev.mihon.injekt.patchInjekt
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.source.MihonPreferences
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.source.online.MihonRuntime
import dalvik.system.DexClassLoader
import dalvik.system.DexFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.Headers
import java.io.File
import uy.kohesive.injekt.api.FullTypeReference
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/** Android-only, in-process Mihon extension host. APKs are never installed. */
class MihonHost(private val context: Context) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("mihon.host", Context.MODE_PRIVATE)
    private val loaded = ConcurrentHashMap<String, LoadedExtension>()

    init {
        patchInjekt()
        val injekt = Class.forName("uy.kohesive.injekt.InjektKt")
            .getMethod("getInjekt").invoke(null)
        injekt.javaClass.methods.first { it.name == "addSingleton" && it.parameterTypes.size == 2 }
            .invoke(injekt, object : FullTypeReference<Application>() {}, app as Application)
        // Extension common-utils resolves this exact type during static init.
        // Match Mihon's tolerant public API decoding policy.
        injekt.javaClass.methods.first { it.name == "addSingleton" && it.parameterTypes.size == 2 }
            .invoke(injekt, object : FullTypeReference<Json>() {}, Json {
                ignoreUnknownKeys = true
                explicitNulls = false
            })
        MihonPreferences.install(app)
        MihonRuntime.install(NetworkHelper(app))
    }

    @Synchronized fun metadata(apkPath: String?, packageName: String?, versionCode: Long?): Map<String, Any?> {
        return try {
            val staged = validatePrivatePath(apkPath ?: error("apkPath is required"))
            require(!packageName.isNullOrBlank()) { "packageName is required" }
            val info = app.packageManager.getPackageArchiveInfo(staged.absolutePath, archiveFlags())
                ?: error("APK manifest could not be read")
            require(info.packageName == packageName) { "package mismatch" }
            val actualVersion = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            require(versionCode == null || actualVersion == versionCode) { "version mismatch: $actualVersion" }
            val signer = signerSha256(staged)
            val hash = sha256(staged)
            checkUpdate(info.packageName, actualVersion, signer, hash)
            mapOf("ok" to true, "packageName" to info.packageName, "versionCode" to actualVersion,
                "versionName" to info.versionName, "signerSha256" to signer,
                "sha256" to hash, "stagedPath" to staged.absolutePath, "signatureVerified" to true,
                "nsfw" to declaredNsfw(info))
        } catch (error: Throwable) {
            mapOf("ok" to false, "error" to rootMessage(error))
        }
    }

    @Synchronized fun inspect(
        apkPath: String?, packageName: String?, versionCode: Long?, signerSha256: String?,
        apkSha256: String? = null,
    ): Map<String, Any?> {
        return try {
            val input = validatePrivatePath(apkPath ?: error("apkPath is required"))
            val staged = stage(input, packageName ?: error("packageName is required"))
            val archive = app.packageManager.getPackageArchiveInfo(
                staged.absolutePath,
                archiveFlags(),
            ) ?: error("APK manifest could not be read")
            val actualPackage = archive.packageName
            require(actualPackage == packageName) { "package mismatch: $actualPackage" }
            if (versionCode != null) {
                val actualVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
                require(actualVersion == versionCode) { "version mismatch: $actualVersion" }
            }
            val signer = signerSha256(staged)
            val hash = sha256(staged)
            require(apkSha256 == null || hash.equals(apkSha256, true)) { "APK content hash mismatch" }
            val actualVersion = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong()
            require(!signerSha256.isNullOrBlank()) { "trusted signer fingerprint is required" }
            require(signer.equals(signerSha256, true)) { "signer mismatch" }
            checkUpdate(actualPackage, actualVersion, signer, hash)
            val abi = archive.versionName?.substringBeforeLast('.')
            require(abi in listOf("1.4", "1.6")) { "unsupported extension ABI: $abi" }
            require(staged.length() > 0) { "empty APK" }
            val dex = ChildFirstDexClassLoader(staged.absolutePath, app.codeCacheDir.absolutePath, app.classLoader)
            val discovered = discoverSources(dex, staged, actualPackage)
            val sources = discovered.second
            require(sources.isNotEmpty()) { "extension contains no sources" }
            val loadedExtension = LoadedExtension(staged, actualPackage, signer, dex, discovered.first, sources)
            val persisted = prefs.edit()
                .putString("apk.$actualPackage", staged.absolutePath)
                .putString("signer.$actualPackage", signer)
                .putString("hash.$actualPackage", hash)
                .putLong("version.$actualPackage", if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else archive.versionCode.toLong())
                .commit()
            require(persisted) { "publisher pin persistence failed; previous runtime retained" }
            loaded[actualPackage] = loadedExtension
            mapOf(
                "ok" to true, "packageName" to actualPackage, "versionCode" to actualVersion,
                "versionName" to archive.versionName,
                "signerSha256" to signer, "factoryLoaded" to (discovered.first?.let { SourceFactory::class.java.isAssignableFrom(dex.loadClass(it)) } == true), "executable" to true,
                "abi" to abi,
                "nsfw" to declaredNsfw(archive),
                "sourceCount" to sources.size, "sources" to sources.map(::sourceMap),
                "sha256" to hash, "stagedPath" to staged.absolutePath, "signatureVerified" to true,
            )
        } catch (error: Throwable) {
            Log.e("MihonHost", "Mihon extension inspect failed", error)
            mapOf("ok" to false, "factoryLoaded" to false, "executable" to false, "hostError" to rootMessage(error))
        }
    }

    fun setEnabled(packageName: String, enabled: Boolean): Map<String, Any?> {
        val persisted = prefs.edit().putBoolean("enabled.$packageName", enabled).commit()
        return mapOf("ok" to persisted, "packageName" to packageName, "enabled" to enabled)
    }

    fun request(args: Map<*, *>): Map<String, Any?> {
        val packageName = args["packageName"]?.toString() ?: error("packageName is required")
        check(prefs.getBoolean("enabled.$packageName", false)) { "extension is disabled" }
        val extension = loaded[packageName] ?: loadPersisted(packageName, args)
            ?: error("extension is not loaded; inspect it first")
        val source = selectSource(extension.sources, args["sourceId"]?.toString())
        val operation = args["operation"]?.toString() ?: error("operation is required")
        val payload = runBlocking(Dispatchers.IO) {
            when (operation) {
                "search" -> mangaPage(source.getSearchManga((args["page"] as? Number)?.toInt() ?: 1, args["query"]?.toString() ?: "", MihonFilters.apply(source.getFilterList(), args["filters"])))
                "popular" -> mangaPage(source.getPopularManga((args["page"] as? Number)?.toInt() ?: 1))
                "latest" -> mangaPage(source.getLatestUpdates((args["page"] as? Number)?.toInt() ?: 1))
                "filters" -> mapOf("filters" to MihonFilters.describe(source.getFilterList()))
                "relatedInfo" -> mapOf("supported" to (source.supportsRelatedMangas && !source.disableRelatedMangas))
                "related" -> {
                    require(source.supportsRelatedMangas && !source.disableRelatedMangas) { "Source does not expose related works" }
                    mapOf("mangas" to source.fetchRelatedMangaList(mangaFrom(args["manga"])).map(::mangaMap))
                }
                "browserInfo" -> {
                    require(source is HttpSource) { "source does not expose a website" }
                    mapOf("url" to source.getHomeUrl(), "userAgent" to (source.headers["User-Agent"]
                        ?: source.network.defaultUserAgentProvider()))
                }
                "detail" -> mangaMap(source.getMangaUpdate(mangaFrom(args["manga"]), emptyList(), true, false).manga)
                "chapters" -> mapOf("chapters" to source.getMangaUpdate(mangaFrom(args["manga"]), emptyList(), false, true).chapters.map(::chapterMap))
                "pages" -> mapOf("pages" to source.getPageList(chapterFrom(args["chapter"])).map(::pageMap))
                "image" -> image(source, pageFrom(args["pageData"] ?: args["page"]))
                "imageFile" -> image(source, pageFrom(args["pageData"]), fileOnly = true)
                else -> error("unsupported operation: $operation")
            }
        }
        return payload + ("ok" to true)
    }

    private fun image(source: Source, page: Page, fileOnly: Boolean = false): Map<String, Any?> {
        require(source is HttpSource) { "source does not expose imageRequest" }
        if (page.imageUrl.isNullOrEmpty()) {
            page.imageUrl = runBlocking(Dispatchers.IO) { source.getImageUrl(page) }
        }
        val request = source.imageRequest(page)
        val cache = File(app.cacheDir, "mihon-images").also { it.mkdirs() }
        val key = sha256(("${source.id}\n${request.url}\n${request.headers}").toByteArray())
        val cached = File(cache, "$key.image")
        val mimeFile = File(cache, "$key.mime")
        if (fileOnly && cached.isFile && cached.length() > 0 && mimeFile.isFile) {
            return mapOf("filePath" to cached.absolutePath, "mime" to mimeFile.readText(), "url" to request.url.toString(), "headers" to request.headers.toMap())
        }
        source.client.newCall(request).execute().use { response ->
            response.requireSuccessful()
            val mime = response.header("Content-Type") ?: "image/jpeg"
            require(mime.startsWith("image/")) { "Image request returned $mime" }
            if (fileOnly) {
                val temporary = File.createTempFile(key, ".tmp", cache)
                try {
                    response.body.byteStream().use { input -> temporary.outputStream().use { input.copyTo(it) } }
                    require(temporary.length() > 0) { "Image response is empty" }
                    require(temporary.renameTo(cached)) { "Image cache publish failed" }
                    mimeFile.writeText(mime)
                } finally {
                    temporary.delete()
                }
                return mapOf("filePath" to cached.absolutePath, "mime" to mime, "url" to request.url.toString(), "headers" to request.headers.toMap())
            }
            return mapOf(
                "bytes" to (response.body?.bytes() ?: ByteArray(0)),
                "mime" to mime,
                "url" to request.url.toString(),
                "headers" to request.headers.toMap(),
            )
        }
    }

    private fun loadPersisted(packageName: String, args: Map<*, *>): LoadedExtension? {
        val path = args["apkPath"]?.toString() ?: prefs.getString("apk.$packageName", null) ?: return null
        val version = (args["versionCode"] as? Number)?.toLong() ?: prefs.getLong("version.$packageName", -1).takeIf { it >= 0 }
        val signer = args["signerSha256"]?.toString() ?: prefs.getString("signer.$packageName", null)
        val result = inspect(path, packageName, version, signer)
        return if (result["ok"] == true) loaded[packageName] else null
    }

    private fun selectSource(sources: List<Source>, requested: String?): Source {
        if (requested.isNullOrBlank()) return sources.firstOrNull() ?: error("extension has no sources")
        return sources.firstOrNull { it.id.toString() == requested || it.name == requested }
            ?: error("source not found: $requested")
    }

    fun settingsSource(packageName: String, sourceId: String): ConfigurableSource {
        check(prefs.getBoolean("enabled.$packageName", false)) { "extension is disabled" }
        val extension = loaded[packageName] ?: loadPersisted(packageName, emptyMap<String, Any>())
            ?: error("extension is not loaded")
        return selectSource(extension.sources, sourceId) as? ConfigurableSource
            ?: error("此来源没有可配置设置")
    }

    /** Static update policy: inspecting a backup must never mutate publisher pins. */
    private fun checkUpdate(packageName: String, version: Long, signer: String, hash: String) {
        prefs.getString("signer.$packageName", null)?.let { previousSigner ->
            require(signer.equals(previousSigner, true)) { "update signer mismatch" }
            val previousVersion = prefs.getLong("version.$packageName", -1)
            require(version >= previousVersion) { "update version downgrade rejected" }
            val previousHash = prefs.getString("hash.$packageName", null)
                ?: prefs.getString("apk.$packageName", null)?.let { path ->
                    File(path).takeIf { it.isFile }?.let(::sha256)
                }
            if (version == previousVersion && previousHash != null) {
                require(hash == previousHash) { "same-version APK hash mismatch" }
            }
        }
    }

    private fun stage(input: File, packageName: String): File {
        val dir = File(app.filesDir, "mihon-staging").also { it.mkdirs() }
        require(!java.nio.file.Files.isSymbolicLink(dir.toPath())) { "APK staging directory symlink is forbidden" }
        val safe = packageName.replace(Regex("[^A-Za-z0-9._-]"), "_")
        // Content-addressed files leave the active APK intact until the candidate
        // has passed metadata, signer and runtime loading checks.
        val expectedHash = sha256(input)
        val target = File(dir, "$safe-$expectedHash.apk")
        require(!java.nio.file.Files.isSymbolicLink(target.toPath())) { "APK staging symlink is forbidden" }
        if (input.canonicalPath != target.canonicalPath) {
            // The published staging file is immutable. Copy into a private
            // temporary sibling first so an interrupted update never leaves a
            // truncated APK, then replace the previous read-only file.
            if (target.isFile) {
                validatePrivatePath(target.absolutePath)
                require(sha256(target) == expectedHash) { "Previously staged APK bytes are corrupt; previous runtime retained" }
                return target.also { it.setWritable(false, false) }
            }
            val temporary = File.createTempFile(safe, ".tmp", dir)
            try {
                input.inputStream().use { source ->
                    temporary.outputStream().use { destination -> source.copyTo(destination) }
                }
                require(temporary.length() in 1..(64L * 1024 * 1024)) { "APK staging exceeds size limit" }
                require(sha256(temporary) == expectedHash) { "APK changed during staging" }
                require(temporary.renameTo(target)) { "APK staging publish failed" }
            } finally {
                temporary.delete()
            }
        }
        target.setReadable(true, true)
        require(target.setWritable(false, false)) { "Unable to make staged APK read-only" }
        target.setExecutable(false, false)
        return target
    }

    private fun validatePrivatePath(path: String): File {
        val original = File(path).absoluteFile
        var ancestor: File? = original
        while (ancestor != null) {
            val systemAlias = (ancestor.path == "/data/user/0" && ancestor.canonicalPath == "/data/data") ||
                (ancestor.path == "/data/data" && ancestor.canonicalPath == "/data/user/0")
            require(systemAlias || !java.nio.file.Files.isSymbolicLink(ancestor.toPath())) { "APK symlink path is forbidden" }
            ancestor = ancestor.parentFile
        }
        val file = original.canonicalFile
        val root = File(app.applicationInfo.dataDir).canonicalFile
        require(file.path == root.path || file.path.startsWith(root.path + File.separator)) { "APK must be in app-private storage" }
        require(file.isFile) { "APK does not exist" }
        require(file.length() in 1..(64L * 1024 * 1024)) { "APK exceeds 64 MiB or is empty" }
        return file
    }

    private fun discoverSources(loader: ClassLoader, staged: File, packageName: String): Pair<String?, List<Source>> {
        findFactory(loader, staged)?.let { factoryClass ->
            val factory = factoryClass.getDeclaredConstructor().newInstance() as SourceFactory
            return factoryClass.name to factory.createSources()
        }
        // Some current 1.6 extensions generate a single `keiyoushi.source.Generated`
        // HttpSource instead of a SourceFactory. Treat that class as the one source;
        // it is still a normal source-api 1.6 implementation and must not be lost
        // merely because its generated package is outside the extension package.
        listOf("keiyoushi.source.Generated").forEach { name ->
            try {
                val type = loader.loadClass(name)
                if (HttpSource::class.java.isAssignableFrom(type) &&
                    !java.lang.reflect.Modifier.isAbstract(type.modifiers)
                ) {
                    @Suppress("UNCHECKED_CAST")
                    val source = type.getDeclaredConstructor().apply { isAccessible = true }.newInstance() as Source
                    return name to listOf(source)
                }
            } catch (_: Throwable) { }
        }
        val legacy = DexFile(staged.absolutePath).entries().asSequence()
            .filter { it.startsWith("$packageName.") && !it.contains('$') }
            .mapNotNull { name ->
                try {
                    val type = loader.loadClass(name)
                    if (!HttpSource::class.java.isAssignableFrom(type) || java.lang.reflect.Modifier.isAbstract(type.modifiers)) {
                        null
                    } else {
                        @Suppress("UNCHECKED_CAST")
                        type.getDeclaredConstructor().apply { isAccessible = true }.newInstance() as Source
                    }
                } catch (error: Throwable) {
                    Log.w("MihonHost", "Unable to instantiate legacy source $name", error)
                    null
                }
            }
            .toList()
        require(legacy.isNotEmpty()) { "SourceFactory class not found and no legacy HttpSource found" }
        return null to legacy
    }

    private fun findFactory(loader: ClassLoader, staged: File): Class<*>? {
        val candidates = listOf("keiyoushi.source.Generated")
        for (name in candidates) try {
            val type = loader.loadClass(name)
            if (SourceFactory::class.java.isAssignableFrom(type)) return type
        } catch (_: Throwable) { }
        // Published repositories use a generated factory name. Inspect DEX entries
        // to support other generators without accepting arbitrary plugin classes.
        DexFile(staged.absolutePath).entries().asSequence().filter { it.endsWith("Generated") || it.endsWith("SourceFactory") }.forEach { name ->
                try {
                    val type = loader.loadClass(name)
                    if (SourceFactory::class.java.isAssignableFrom(type)) return type
                } catch (_: Throwable) { }
        }
        return null
    }

    private fun archiveFlags(): Int = PackageManager.GET_META_DATA or
        (if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)

    private fun signerSha256(file: File): String {
        val result = ApkVerifier.Builder(file).setMinCheckedPlatformVersion(26).build().verify()
        require(result.isVerified) { "APK cryptographic signature verification failed" }
        require(result.signerCertificates.size == 1) { "APK must have exactly one publisher signer" }
        return sha256(result.signerCertificates.single().encoded)
    }

    private fun sha256(file: File): String = file.inputStream().use { sha256(it.readBytes()) }
    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun sourceMap(source: Source) = mapOf("id" to source.id.toString(), "name" to source.name, "lang" to source.lang, "supportsLatest" to source.supportsLatest)

    private fun declaredNsfw(info: android.content.pm.PackageInfo): Boolean? {
        val raw = info.applicationInfo?.metaData?.get("tachiyomi.extension.nsfw")
        return when (raw) {
            is Boolean -> raw
            0 -> false
            1 -> true
            else -> null
        }
    }
    private fun mangaPage(page: MangasPage) = mapOf("mangas" to page.mangas.map(::mangaMap), "hasNextPage" to page.hasNextPage)
    private fun mangaMap(manga: SManga) = mapOf("url" to manga.url, "title" to manga.title, "thumbnailUrl" to manga.thumbnail_url, "artist" to manga.artist, "author" to manga.author, "status" to manga.status, "description" to manga.description, "genre" to manga.genre, "initialized" to manga.initialized)
    private fun chapterMap(chapter: SChapter) = mapOf("url" to chapter.url, "name" to chapter.name, "chapterNumber" to chapter.chapter_number, "scanlator" to chapter.scanlator, "dateUpload" to chapter.date_upload)
    private fun pageMap(page: Page) = mapOf("index" to page.index, "url" to page.url, "imageUrl" to page.imageUrl)

    private fun mangaFrom(raw: Any?): SManga = (raw as? Map<*, *>)?.let { map -> SManga.create().also { it.url = map["url"]?.toString() ?: ""; it.title = map["title"]?.toString() ?: ""; it.thumbnail_url = map["thumbnailUrl"]?.toString(); it.artist = map["artist"]?.toString(); it.author = map["author"]?.toString(); it.status = (map["status"] as? Number)?.toInt() ?: 0; it.description = map["description"]?.toString(); it.genre = map["genre"]?.toString(); it.initialized = map["initialized"] as? Boolean ?: false } } ?: error("manga is required")
    private fun chapterFrom(raw: Any?): SChapter = (raw as? Map<*, *>)?.let { map -> SChapter.create().also { it.url = map["url"]?.toString() ?: ""; it.name = map["name"]?.toString() ?: ""; it.chapter_number = (map["chapterNumber"] as? Number)?.toFloat() ?: -1f; it.scanlator = map["scanlator"]?.toString(); it.date_upload = (map["dateUpload"] as? Number)?.toLong() ?: 0L } } ?: error("chapter is required")
    private fun pageFrom(raw: Any?): Page = (raw as? Map<*, *>)?.let { map -> Page((map["index"] as? Number)?.toInt() ?: 0, map["url"]?.toString() ?: "", map["imageUrl"]?.toString()) } ?: error("page is required")

    private fun rootMessage(error: Throwable): String = generateSequence(error) { it.cause }.last().message ?: error::class.java.simpleName
    private data class LoadedExtension(val apk: File, val packageName: String, val signer: String, val loader: ClassLoader, val factory: String?, val sources: List<Source>)

    private class ChildFirstDexClassLoader(path: String, optimizedDirectory: String, parent: ClassLoader) : DexClassLoader(path, optimizedDirectory, null, parent) {
        private val parentPrefixes = arrayOf("android.", "androidx.", "kotlin.", "kotlinx.", "okhttp3.", "okio.", "rx.", "eu.kanade.tachiyomi.", "uy.kohesive.injekt.", "dev.mihon.injekt.")
        override fun loadClass(name: String, resolve: Boolean): Class<*> {
            if (parentPrefixes.any(name::startsWith)) return super.loadClass(name, resolve)
            synchronized(name.intern()) {
                findLoadedClass(name)?.let { return it }
                try { return findClass(name) } catch (_: ClassNotFoundException) { return super.loadClass(name, resolve) }
            }
        }
    }
}

private fun okhttp3.Response.requireSuccessful(): okhttp3.Response {
    if (!isSuccessful) throw java.io.IOException("HTTP $code: $message")
    return this
}
