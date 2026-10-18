import java.util.Properties

// Kredensial keystore dibaca dari android/key.properties yang tidak ikut version
// control. Selama file itu belum ada, build release jatuh ke kunci debug supaya
// `flutter run --release` tetap bisa dipakai untuk pengujian lokal.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bohantar.mobile"
    // flutter_secure_storage menuntut SDK 37; nilai bawaan Flutter masih 36.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Dituntut flutter_local_notifications sejak versi 10.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bohantar.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Kunci Maps SDK untuk menggambar peta. Ikut ke dalam APK, jadi di
        // Google Cloud dibatasi ke package + SHA-1; nilainya ikut key.properties
        // supaya tidak masuk git.
        val mapsApiKey = keystoreProperties.getProperty("mapsApiKey") ?: ""
        if (mapsApiKey.isBlank()) logger.warn("PERINGATAN: mapsApiKey belum ada di android/key.properties — peta Google tampil kosong.")
        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
    }

    signingConfigs {
        if (hasReleaseKeystore) {
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
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("PERINGATAN: android/key.properties tidak ada — build release memakai kunci debug dan TIDAK bisa diunggah ke Play Store.")
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
