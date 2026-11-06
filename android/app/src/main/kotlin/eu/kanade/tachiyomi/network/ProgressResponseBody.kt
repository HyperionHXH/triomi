package eu.kanade.tachiyomi.network

import okhttp3.MediaType
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer

class ProgressResponseBody(
    private val responseBody: ResponseBody,
    private val progressListener: ProgressListener,
) : ResponseBody() {
    private val bufferedSource: BufferedSource by lazy {
        object : ForwardingSource(responseBody.source()) {
            private var totalBytesRead = 0L

            override fun read(sink: Buffer, byteCount: Long): Long {
                val bytesRead = super.read(sink, byteCount)
                if (bytesRead != -1L) totalBytesRead += bytesRead
                progressListener.update(totalBytesRead, contentLength(), bytesRead == -1L)
                return bytesRead
            }
        }.buffer()
    }

    override fun contentType(): MediaType? = responseBody.contentType()
    override fun contentLength(): Long = responseBody.contentLength()
    override fun source(): BufferedSource = bufferedSource
}
