plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "km.hawiya.hawiya"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "km.hawiya.hawiya"
        // Android 8.0 minimum : Keystore matériel (phase 1 bis) et CameraX récent.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Le modèle MediaPipe doit rester non compressé pour être lu directement depuis l'APK.
    androidResources {
        noCompress.add("task")
    }

    buildTypes {
        release {
            // Signature de démo avec la clé de debug : un vrai certificat viendra en phase 9.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Caméra (aperçu + analyse en direct + photo pleine résolution)
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")

    // Détection de la main et des 21 points de repère
    implementation("com.google.mediapipe:tasks-vision:0.10.21")

    // Tests sur PC des calculs de qualité (android/app/src/test)
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
