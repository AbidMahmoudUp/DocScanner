plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}


/// Maps Flutter's `target-platform` property onto Android ABI names, falling
/// back to every ABI OpenCV supports when the property is absent.
fun abisForRequestedPlatforms(): List<String> {
    val supported = mapOf(
        "android-arm" to "armeabi-v7a",
        "android-arm64" to "arm64-v8a",
        "android-x64" to "x86_64",
    )
    val requested = (project.findProperty("target-platform") as String?)
        ?.split(",")
        ?.mapNotNull { supported[it.trim()] }
        ?.distinct()
    return if (requested.isNullOrEmpty()) supported.values.toList() else requested
}

android {
    namespace = "com.itpidia.doc_scanner"
    compileSdk = flutter.compileSdkVersion
    // Pinned: opencv_core builds its native library with ANDROID_STL
    // c++_static, which fails to link against the NDK 28 toolchain Flutter
    // defaults to. NDK 26 links it cleanly.
    ndkVersion = "26.3.11579264"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.itpidia.doc_scanner"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // OpenCV's prebuilt native libraries need API 24 or newer.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // The ABIs OpenCV ships prebuilt binaries for (there is no x86
            // build). Each one carries ~70MB of native libraries, so honour
            // `flutter build apk --target-platform ...` here too and ship only
            // what was asked for.
            abiFilters += abisForRequestedPlatforms()
        }
    }

    packaging {
        // OpenCV and the camera plugin can both contribute the same STL; take
        // the first rather than failing the merge.
        jniLibs {
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
