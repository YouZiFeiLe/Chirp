import java.security.MessageDigest
import javax.inject.Inject
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.file.ArchiveOperations
import org.gradle.process.ExecOperations
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

abstract class PrepareLiveKit @Inject constructor(
    private val files: FileSystemOperations,
    private val processes: ExecOperations,
    private val archives: ArchiveOperations,
) : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val sources: ConfigurableFileCollection

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val hardeningPatch: RegularFileProperty

    @get:OutputDirectory
    abstract val output: DirectoryProperty

    @TaskAction
    fun prepare() {
        val source = sources.singleFile
        val sha = MessageDigest.getInstance("SHA-256").digest(source.readBytes())
            .joinToString("") { "%02x".format(it) }
        check(sha == "3b6f3edebade43100dc25eadad0ecfa951259d156f8a7e0912dc16e3d49c8869") {
            "Unexpected LiveKit sources archive"
        }
        files.sync {
            from(archives.zipTree(source))
            exclude("META-INF/**")
            into(output)
        }
        processes.exec {
            workingDir(output.get().asFile)
            commandLine("patch", "--batch", "--fuzz=0", "-p1", "-i", hardeningPatch.get().asFile)
        }
    }
}

val upstreamSources = configurations.create("upstreamSources") {
    isTransitive = false
    isCanBeConsumed = false
}
val prepareLiveKit = tasks.register<PrepareLiveKit>("prepareLiveKit") {
    sources.from(upstreamSources)
    hardeningPatch.set(rootProject.file("patches/livekit-2.30.0.patch"))
    output.set(layout.buildDirectory.dir("generated/livekit"))
}

android {
    namespace = "io.livekit.android"
    compileSdk {
        version = release(37) { minorApiLevel = 2 }
    }

    defaultConfig {
        minSdk = 35
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

androidComponents.onVariants { variant ->
    variant.sources.java?.addGeneratedSourceDirectory(prepareLiveKit, PrepareLiveKit::output)
    variant.sources.kotlin?.addGeneratedSourceDirectory(prepareLiveKit, PrepareLiveKit::output)
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
        optIn.add("io.livekit.android.annotations.Beta")
    }
}

dependencies {
    add(upstreamSources.name, "io.livekit:livekit-android:${libs.versions.livekit.get()}:sources@jar")
    api("io.github.webrtc-sdk:android-prefixed:150.7871.08")
    api("com.github.davidliu:audioswitch:039a35aefab7747c557242fa216c9ea11743b604")
    api("com.vdurmont:semver4j:3.1.0")
    api("com.google.protobuf:protobuf-javalite:4.36.2")
    implementation(libs.okhttp)
    implementation(libs.coroutines)
    implementation(libs.serialization)
    implementation(libs.core)
    implementation("io.livekit:livekit-ffi-android:0.15.0")
    implementation("com.auth0.android:jwtdecode:2.1.0")
    implementation("javax.sip:android-jain-sip-ri:1.3.0-91")
    implementation("com.google.dagger:dagger:2.60.1")
    testImplementation(libs.junit)
    constraints {
        api(libs.jetbrains.annotations)
        api(libs.jspecify)
        api(libs.annotation.core)
        api(libs.annotation.experimental)
        api(libs.collection.core)
        api(libs.concurrent.futures)
        api(libs.lifecycle.runtime)
        api(libs.profileinstaller)
        api(libs.tracing)
        api(libs.versionedparcelable)
        api(libs.okio)
        api(libs.gson)
        api(libs.errorprone.annotations)
        testImplementation(libs.hamcrest.core)
    }
}
