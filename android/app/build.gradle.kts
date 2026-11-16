import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma de release: android/key.properties (NO versionado, ver android/.gitignore)
// apunta a un keystore fuera del repo. Si no existe (otra máquina/CI sin la llave)
// los builds de DEBUG siguen funcionando (llave debug), pero un build de
// RELEASE sin llave FALLA (S-10): un APK de release firmado con la llave debug
// no se puede actualizar y es fácil de suplantar. Solo se permite
// explícitamente con ALLOW_DEBUG_SIGNED_RELEASE=true (variable de entorno o
// -PALLOW_DEBUG_SIGNED_RELEASE=true), pensado solo para CI sin keystore.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keyProps.containsKey("storeFile")
val allowDebugSignedRelease =
    (System.getenv("ALLOW_DEBUG_SIGNED_RELEASE") ?: "").equals("true", ignoreCase = true) ||
        (project.findProperty("ALLOW_DEBUG_SIGNED_RELEASE")?.toString() ?: "")
            .equals("true", ignoreCase = true)

gradle.taskGraph.whenReady {
    val releaseRequested = allTasks.any {
        it.project == project &&
            (it.name.contains("Release") || it.name.contains("release")) &&
            (it.name.startsWith("assemble") || it.name.startsWith("bundle") ||
                it.name.startsWith("package") || it.name.startsWith("sign") ||
                it.name.startsWith("validateSigning"))
    }
    if (releaseRequested && !hasReleaseKey && !allowDebugSignedRelease) {
        throw GradleException(
            "Falta android/key.properties: un build de release no se firma con la " +
                "llave debug. Crea key.properties (storeFile, storePassword, keyAlias, " +
                "keyPassword) o, solo en CI, define ALLOW_DEBUG_SIGNED_RELEASE=true."
        )
    }
}

android {
    namespace = "com.saumnty.vault"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.saumnty.vault"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyProps.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keyProps.containsKey("storeFile"))
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // biometric_storage exige que el tema de la Activity herede de Theme.AppCompat
    // (si no, BiometricPrompt falla en Android < 10). Ver styles.xml.
    implementation("androidx.appcompat:appcompat:1.7.0")
}
