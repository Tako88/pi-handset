import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release key lives outside the repository: `key.properties` is gitignored and
// points at a keystore in the user's home directory. Absent, a release build still
// runs — signed with the per-machine debug key, which cannot update an install made
// anywhere else — so the build warns and the release step verifies the signature.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "io.github.tako88.pihandset"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.tako88.pihandset"
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
        // Only defined when the key is actually present, so a clean checkout (and CI)
        // still configures the release variant.
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// A release APK signed with the per-machine debug key cannot update an install made
// anywhere else, and the mistake stays invisible until someone's phone refuses the
// update — so the release path refuses to produce one unless the debug key is asked for
// by name. `ALLOW_DEBUG_SIGNED_RELEASE=1` is the deliberate opt-out (an environment
// variable rather than a Gradle property, because `flutter build` gives no way to pass
// -P through).
val allowDebugSignedRelease = providers.environmentVariable("ALLOW_DEBUG_SIGNED_RELEASE").isPresent

// A task with no declared outputs always runs, which is what this needs: a
// configuration-time check cannot tell whether the release variant is the one being
// built (it would fail profile builds too), and a `doFirst` on assembleRelease is
// skipped whenever that task is up-to-date.
val refuseDebugSignedRelease = tasks.register("refuseDebugSignedRelease") {
    doLast {
        if (!keystorePropertiesFile.exists() && !allowDebugSignedRelease) {
            throw GradleException(
                "app/android/key.properties is missing, so this release APK would be signed with " +
                    "the DEBUG key, which cannot update an installed app that was signed " +
                    "elsewhere. Create the keystore (docs/development.md, 'Release signing'), or " +
                    "set ALLOW_DEBUG_SIGNED_RELEASE=1 to build a debug-signed release on purpose.",
            )
        }
    }
}

tasks.matching { it.name == "assembleRelease" }.configureEach { dependsOn(refuseDebugSignedRelease) }

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
