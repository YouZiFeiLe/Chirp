package cn.youzifeile.chirp.data

import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseCorruptException
import androidx.core.database.sqlite.transaction
import java.io.File
import java.io.IOException
import java.util.UUID

internal data class LogRow(val time: Long, val event: LogEvent, val outcome: LogOutcome?, val error: String?,
    val duration: Long?, val status: Int?, val details: LogDetails?, val segment: String, val seq: Long)

/** Confined to the installation's single writer, including snapshot creation and deletion. */
internal class ChirpLogStore(private val directory: File) {
    companion object {
        const val HOUR = 3_600_000L
        const val RETENTION = 24 * HOUR
        const val APPLICATION_ID = 0x43485250
        private const val COLUMNS = "time_ms, event, outcome, error_code, duration_us, http_status, details, segment, seq"
        private val shardName = Regex("""(-?\d+)\.chirplog(?:-(?:journal|wal|shm))?""")
        private fun hour(time: Long) = Math.floorDiv(time, HOUR)
    }

    private var writerHour: Long? = null
    private var writer: SQLiteDatabase? = null

    fun close() {
        writer?.close()
        writer = null
        writerHour = null
    }

    private fun open(file: File, create: Boolean = false): SQLiteDatabase {
        val fresh = !file.exists()
        if (fresh && !create) throw IOException("Missing log shard")
        val options = SQLiteDatabase.OpenParams.Builder()
            .setErrorHandler { throw SQLiteDatabaseCorruptException("Invalid chirplog") }
        if (!fresh) {
            val readOnly = options.setOpenFlags(SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS).build()
            SQLiteDatabase.openDatabase(file, readOnly).use { validate(it, "main") }
        }
        val flags = SQLiteDatabase.NO_LOCALIZED_COLLATORS or (if (fresh) SQLiteDatabase.CREATE_IF_NECESSARY else 0)
        val params = options.setOpenFlags(flags).setJournalMode("DELETE").setSynchronousMode("NORMAL").build()
        val db = SQLiteDatabase.openDatabase(file, params)
        try {
            DatabaseUtils.longForQuery(db, "PRAGMA secure_delete=ON", null)
            if (fresh) db.transaction {
                execSQL("PRAGMA application_id=$APPLICATION_ID")
                version = 1
                for (table in LogTable.entries) {
                    execSQL("CREATE TABLE $table (time_ms INTEGER NOT NULL, event TEXT NOT NULL, outcome TEXT, " +
                        "error_code TEXT, duration_us INTEGER, http_status INTEGER, details TEXT, segment TEXT NOT NULL, seq INTEGER NOT NULL)")
                    execSQL("CREATE INDEX ${table}_time ON $table(time_ms)")
                }
            }
            return db
        } catch (e: Exception) {
            db.close()
            if (fresh) SQLiteDatabase.deleteDatabase(file)
            throw e
        }
    }

    private fun validate(db: SQLiteDatabase, schema: String) {
        if (DatabaseUtils.longForQuery(db, "PRAGMA $schema.application_id", null) != APPLICATION_ID.toLong() ||
            DatabaseUtils.longForQuery(db, "PRAGMA $schema.user_version", null) != 1L) throw IOException("Unsupported chirplog")
    }

    private fun ensureDirectory() {
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create log directory")
    }

    fun write(rows: List<LogRow>) {
        if (rows.isEmpty()) return
        val hour = hour(rows.first().time)
        if (hour != writerHour) {
            close()
            ensureDirectory()
            writer = open(File(directory, "$hour.chirplog"), create = true)
            writerHour = hour
        }
        try {
            checkNotNull(writer).transaction {
                for ((table, events) in rows.groupBy { it.event.table }) {
                    compileStatement("INSERT INTO $table ($COLUMNS) VALUES (?,?,?,?,?,?,?,?,?)").use { insert ->
                        for (row in events) {
                            insert.clearBindings()
                            insert.bindLong(1, row.time)
                            insert.bindString(2, row.event.name)
                            row.outcome?.let { insert.bindString(3, it.name) }
                            row.error?.let { insert.bindString(4, it) }
                            row.duration?.let { insert.bindLong(5, it) }
                            row.status?.let { insert.bindLong(6, it.toLong()) }
                            row.details?.let { insert.bindString(7, it.json(row.error).toString()) }
                            insert.bindString(8, row.segment)
                            insert.bindLong(9, row.seq)
                            insert.executeInsert()
                        }
                    }
                }
            }
        } catch (e: Exception) {
            close()
            throw e
        }
    }

    private fun files(): List<File> = if (!directory.exists()) emptyList()
        else directory.listFiles()?.toList() ?: throw IOException("Cannot list logs")

    private fun hasRows(db: SQLiteDatabase) = LogTable.entries.any {
        DatabaseUtils.longForQuery(db, "SELECT EXISTS(SELECT 1 FROM $it)", null) != 0L
    }

    fun prune(now: Long) {
        val cutoff = now - RETENTION
        val boundary = hour(cutoff)
        if (writerHour?.let { it <= boundary } == true) close()
        for (file in files()) {
            val part = shardName.matchEntire(file.name)?.groupValues?.get(1)?.toLongOrNull() ?: continue
            if (part < boundary) remove(file)
        }
        val file = File(directory, "$boundary.chirplog")
        if (!file.exists()) return
        val empty = open(file).use { db ->
            db.transaction {
                for (table in LogTable.entries) execSQL("DELETE FROM $table WHERE time_ms < ?", arrayOf(cutoff))
                !hasRows(this)
            }
        }
        if (empty && !SQLiteDatabase.deleteDatabase(file)) throw IOException("Cannot delete expired log")
    }

    fun snapshot(now: Long): File? {
        prune(now)
        val cutoff = now - RETENTION
        val shards = files().filter { it.name.endsWith(".chirplog") &&
            it.nameWithoutExtension.toLongOrNull()?.let { n -> n in hour(cutoff)..hour(now) } == true }
        if (shards.isEmpty()) return null
        val file = File(directory, "export-${UUID.randomUUID()}.chirplog")
        try {
            val populated = open(file, create = true).use { db ->
                for (shard in shards) {
                    db.execSQL("ATTACH DATABASE ? AS src", arrayOf(shard.absolutePath))
                    try {
                        validate(db, "src")
                        db.transaction {
                            for (table in LogTable.entries) execSQL("INSERT INTO main.$table ($COLUMNS) " +
                                "SELECT $COLUMNS FROM src.$table WHERE time_ms BETWEEN ? AND ?", arrayOf(cutoff, now))
                        }
                    } finally { db.execSQL("DETACH DATABASE src") }
                }
                hasRows(db)
            }
            if (populated) return file
        } catch (e: Exception) {
            SQLiteDatabase.deleteDatabase(file)
            throw e
        }
        SQLiteDatabase.deleteDatabase(file)
        return null
    }

    private fun remove(file: File) {
        if (!file.delete() && file.exists()) throw IOException("Cannot delete log file")
    }

    fun discardExports() = files().filter { it.name.startsWith("export-") }.forEach(::remove)
    fun clear() {
        close()
        files().forEach(::remove)
    }
}
