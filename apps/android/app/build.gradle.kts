import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repositoryRoot = rootProject.layout.projectDirectory.dir("../..").asFile
val rustOutput = rootProject.layout.buildDirectory.dir("rustJniLibs")
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
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild {
            cmake { arguments += "-DCOLORFUL_CORE_DIR=${rustOutput.get().asFile.absolutePath}" }
        }
    }
    buildFeatures { compose = true }
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
    implementation("androidx.media3:media3-session:1.10.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
