import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repositoryRoot = rootProject.layout.projectDirectory.dir("../..").asFile
val providerEnvironment = repositoryRoot.parentFile.resolve("mocha/.env")
    .takeIf { it.isFile }
    ?.readLines()
    ?.mapNotNull { line ->
        val clean = line.trim()
        if (clean.isEmpty() || clean.startsWith("#") || !clean.contains('=')) null
        else clean.substringBefore('=').trim() to clean.substringAfter('=').trim()
            .removeSurrounding("\"").removeSurrounding("'")
    }
    ?.toMap()
    .orEmpty()

fun providerValue(name: String, fallback: String = ""): String =
    System.getenv(name) ?: providerEnvironment[name] ?: fallback

fun javaString(value: String): String = "\"" + value
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
    .replace("\n", "\\n") + "\""
val rustOutput = rootProject.layout.buildDirectory.dir("rustJniLibs")
val defaultTidalBrowseClientId = "lw3vR6GE1vtNBsjv"
val defaultTidalBrowseClientSecret = "Y8tIpqKJxs9BEIwYr0I9bSbMWDsogXJx9LaN3mCHwD4="
val defaultTidalDeviceClientId = "fX2JxdmntZWK0ixT"
val defaultTidalDeviceClientSecret = "1Nm5AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAvxAg="
val buildRustCore by tasks.registering(Exec::class) {
    workingDir(repositoryRoot)
    environment("COLORFUL_ANDROID_OUT", rustOutput.get().asFile.absolutePath)
    commandLine("bash", "scripts/build-android-core.sh")
    inputs.files(repositoryRoot.resolve("Cargo.toml"), repositoryRoot.resolve("Cargo.lock"))
    inputs.file(repositoryRoot.resolve("scripts/build-android-core.sh"))
    inputs.dir(repositoryRoot.resolve("crates/colorful-core/src"))
    inputs.dir(repositoryRoot.resolve("crates/colorful-core/migrations"))
    outputs.dir(rustOutput)
}

android {
    namespace = "sh.valerie.colorful"
    compileSdk { version = release(36) { minorApiLevel = 1 } }
    ndkVersion = "30.0.15729638"
    defaultConfig {
        applicationId = "sh.valerie.colorful"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "TIDAL_BROWSE_CLIENT_ID", javaString(providerValue("TIDAL_CLIENT_ID", defaultTidalBrowseClientId)))
        buildConfigField("String", "TIDAL_BROWSE_CLIENT_SECRET", javaString(providerValue("TIDAL_CLIENT_SECRET", defaultTidalBrowseClientSecret)))
        buildConfigField("String", "TIDAL_DEVICE_CLIENT_ID", javaString(providerValue("TIDAL_DEVICE_CLIENT_ID", defaultTidalDeviceClientId)))
        buildConfigField("String", "TIDAL_DEVICE_CLIENT_SECRET", javaString(providerValue("TIDAL_DEVICE_CLIENT_SECRET", defaultTidalDeviceClientSecret)))
        buildConfigField("String", "TIDAL_REFRESH_CLIENT_ID", javaString(providerValue("TIDAL_REFRESH_CLIENT_ID", providerValue("TIDAL_CLIENT_ID", defaultTidalBrowseClientId))))
        buildConfigField("String", "TIDAL_REFRESH_CLIENT_SECRET", javaString(providerValue("TIDAL_REFRESH_CLIENT_SECRET", providerValue("TIDAL_CLIENT_SECRET", defaultTidalBrowseClientSecret))))
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild {
            cmake { arguments += "-DCOLORFUL_CORE_DIR=${rustOutput.get().asFile.absolutePath}" }
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }
}

tasks.configureEach {
    if (name.startsWith("configureCMake") || name.startsWith("buildCMake")) dependsOn(buildRustCore)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.06.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.1")
    implementation("androidx.media3:media3-session:1.10.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
