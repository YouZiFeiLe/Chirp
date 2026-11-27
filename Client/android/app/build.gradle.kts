import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.util.Base64
import groovy.json.JsonSlurper

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val signingDirectory = rootProject.file("signing")
val releaseSigning = Properties().apply {
    signingDirectory.resolve("release.properties").inputStream().use { load(it) }
}

val rnnoiseDirectory = layout.buildDirectory.dir("generated/rnnoise")
abstract class PrepareAuthorizationTrust : DefaultTask() {
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val trustFile: RegularFileProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @TaskAction fun prepare() {
        val source = trustFile.get().asFile
        val trust = JsonSlurper().parse(source) as? Map<*, *>
        require(trust?.keys == setOf("public_key")) { "AuthorizationTrust.json must contain only public_key" }
        val key = trust?.get("public_key") as? String ?: error("Missing Ed25519 public key")
        val decoded = Base64.getDecoder().decode(key)
        require(decoded.size == 32 && Base64.getEncoder().encodeToString(decoded) == key) { "Invalid Ed25519 public key" }
        val output = assetsDirectory.file("AuthorizationTrust.json").get().asFile
        output.parentFile.mkdirs()
        source.copyTo(output, overwrite = true)
    }
}
val authorizationAssets = tasks.register<PrepareAuthorizationTrust>("prepareAuthorizationTrust") {
    trustFile.set(rootProject.layout.projectDirectory.file("../apple/Shared/Resources/AuthorizationTrust.json"))
    assetsDirectory.set(layout.buildDirectory.dir("generated/authorization-assets"))
}
abstract class PrepareClientMessages : Exec() {
    @get:OutputDirectory abstract val resourceDir: DirectoryProperty
}
val clientMessages = tasks.register<PrepareClientMessages>("prepareClientMessages") {
    val catalogs = rootProject.file("../apple/Shared/Resources")
    val mapping = project.file("src/main/shared-messages.json")
    val script = rootProject.file("../../scripts/prepare-android-messages.py")
    val nativeResources = project.file("src/main/res")
    inputs.files(script, mapping, fileTree(catalogs) { include("*.lproj/*.strings") },
        fileTree(nativeResources) { include("values/*.xml", "values-zh-rCN/*.xml") })
    resourceDir.set(layout.buildDirectory.dir("generated/client-messages"))
    commandLine(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3",
        script, catalogs, mapping, resourceDir.get().asFile, nativeResources)
}
androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(authorizationAssets, PrepareAuthorizationTrust::assetsDirectory)
    variant.sources.res?.addGeneratedSourceDirectory(clientMessages, PrepareClientMessages::resourceDir)
}
val rnnoiseAssets = layout.buildDirectory.dir("generated/rnnoise-assets")
val prepareRNNoise = tasks.register<Exec>("prepareRNNoise") {
    val repository = rootProject.projectDir.resolve("../..")
    inputs.files(repository.resolve("scripts/prepare-rnnoise.py"),
        repository.resolve("Client/apple/Patches/rnnoise-model-loading.patch"),
        repository.resolve("Client/apple/Patches/rnnoise-0.2-apple/os_support.h"),
        repository.resolve("Client/apple/Audio/Sources/ChirpAudio/RNNoise-LICENSE.txt"))
    outputs.dir(rnnoiseDirectory)
    outputs.dir(rnnoiseAssets)
    commandLine(if (System.getProperty("os.name").startsWith("Windows")) "python" else "python3",
        repository.resolve("scripts/prepare-rnnoise.py"),
        "--output", rnnoiseDirectory.get().asFile)
    doLast {
        copy {
            from(repository.resolve("Client/apple/Audio/Sources/ChirpAudio/RNNoise-LICENSE.txt"))
            into(rnnoiseAssets.get().dir("licenses"))
        }
    }
}
tasks.configureEach {
    if (name == "preBuild" || name.startsWith("configureCMake") || name.startsWith("buildCMake")) dependsOn(prepareRNNoise)
}

android {
    namespace = "cn.youzifeile.chirp"
    compileSdk {
        version = release(37) { minorApiLevel = 2 }
    }
    buildToolsVersion = "37.0.0"
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "cn.youzifeile.chirp.android"
        minSdk = 35
        targetSdk = 37
        // Android upgrades use versionCode. Chirp displays and reports the build within each versionName.
        versionCode = 9
        versionName = "2026.11.27"
        buildConfigField("int", "CLIENT_BUILD", "1")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild.cmake.arguments += "-DCHIRP_RNNOISE_DIR=${rnnoiseDirectory.get().asFile}"
    }

    sourceSets["main"].assets.srcDir(file("../../apple/MLS/Sources/ChirpMLS/Resources"))
    sourceSets["main"].assets.srcDir(rnnoiseAssets.get().asFile)
    sourceSets["test"].resources.srcDir(rootProject.file("../../internal/identity/testdata"))
    sourceSets["androidTest"].assets.srcDir(rootProject.file("../../internal/identity/testdata"))

    signingConfigs {
        create("release") {
            storeFile = signingDirectory.resolve(releaseSigning.getProperty("storeFile"))
            storeType = releaseSigning.getProperty("storeType")
            storePassword = releaseSigning.getProperty("storePassword")
            keyAlias = releaseSigning.getProperty("keyAlias")
            keyPassword = releaseSigning.getProperty("keyPassword")
            enableV1Signing = false
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }
    // The in-app language picker must work offline, including App Bundle installs.
    bundle { language { enableSplit = false } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }
}

kotlin {
    compilerOptions { jvmTarget = JvmTarget.JVM_17 }
}

dependencies {
    // Keep inherited runtime and test libraries on compatible stable releases.
    constraints {
        implementation(libs.collection.ktx)
        implementation(libs.savedstate.core)
        implementation(libs.savedstate.compose)
        implementation(libs.savedstate.ktx)
        implementation(libs.navigationevent.core)
        implementation(libs.navigationevent.compose)
        implementation(libs.autofill)
        implementation(libs.graphics.path)
        implementation(libs.graphics.shapes)
        implementation(libs.camera.viewfinder)
        implementation(libs.appcompat)
        implementation(libs.customview)
        implementation(libs.drawerlayout)
        implementation(libs.fragment)
        implementation(libs.loader)
        implementation(libs.viewpager)
        implementation(libs.vector.animated)
        implementation(libs.media3.muxer)
        implementation(libs.emoji)
        implementation(libs.poolingcontainer)
        implementation(libs.window)
        implementation(libs.atomicfu)
        implementation(libs.guava)
        implementation(libs.auto.value.annotations)
        testImplementation(libs.hamcrest.core)
        androidTestImplementation(libs.hamcrest.core)
        androidTestImplementation(libs.hamcrest.library)
        androidTestImplementation(libs.test.junit)
    }
    implementation(platform(libs.kotlin.bom))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.foundation)
    implementation(libs.compose.material)
    implementation(libs.compose.navigation.suite)

    implementation(libs.activity.compose)
    implementation(libs.adaptive.navigation)
    implementation(libs.browser)
    implementation(libs.core)
    implementation(libs.datastore)
    implementation(libs.lifecycle.compose)
    implementation(libs.lifecycle.viewmodel)
    implementation(libs.navigation.runtime)
    implementation(libs.navigation.ui)
    implementation(libs.telecom)
    implementation(libs.coroutines)
    implementation(libs.serialization)
    implementation(libs.bouncycastle)
    implementation(libs.camera.camera2)
    implementation(libs.camera.lifecycle)
    implementation(libs.camera.view)
    implementation(libs.zxing)
    implementation(libs.okhttp)
    implementation(project(":livekit"))

    testImplementation(libs.junit)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.test.junit)
    androidTestImplementation(libs.test.runner)
    androidTestImplementation(libs.test.rules)
    androidTestImplementation(libs.espresso.core)
    debugImplementation(libs.compose.test.manifest)
}
