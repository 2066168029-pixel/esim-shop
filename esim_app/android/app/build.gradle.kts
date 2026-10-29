plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.esimshop.esim_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // flutter.minSdkVersion on this template is 21. The Linksfield SDK
    // (droidlib-v1.2.0.aar) needs 24 for its Keystore-backed PSK storage, and
    // flutter_blue_plus/security-crypto would drag it up anyway.

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.esimshop.esim_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // The Linksfield AAR ships R8-processed classes that are looked up
            // reflectively (Retrofit call adapters, gRPC stubs, the shaded
            // eUICC DTOs). Without this file the app's own shrinker strips
            // them and the SDK fails *at runtime only* -- reading profiles
            // worked while `enable` died with
            //   "Unable to create call adapter for class tg1".
            // It also means every keep rule in that file was dead text before.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // R8 sees the SDK's entry points as unreferenced (the only callers are
    // reflection-free Kotlin in this module, which R8 keeps separately) and
    // would otherwise strip or rename the shaded eUICC types. The keep rules
    // live in proguard-rules.pro, wired up in buildTypes above.
    packaging {
        jniLibs {
            // Ship only what the SDK and gRPC need; the demo pulls in far more.
            useLegacyPackaging = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Linksfield eSIM Manager SDK. The Flutter UI keeps using esim_ble (pure
    // Dart), but this gives the native side the same LPA stack the vendor demo
    // uses: EuiccBleDevice + LPAdClient over the NUS GATT service.
    implementation(fileTree("libs") { include("*.aar") })

    // Required by the SDK (README 1.0.7). Must match or LPAdClient's gRPC
    // classes fail to link at class-load time.
    implementation("io.grpc:grpc-okhttp:1.64.0")
    implementation("io.grpc:grpc-protobuf-lite:1.64.0")
    implementation("io.grpc:grpc-stub:1.64.0")
    implementation("org.apache.tomcat:annotations-api:6.0.53")

    // Keystore-backed PSK storage for the native BLE path.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Undeclared SDK dependencies. droidlib-v1.2.0.aar's POM lists none of these,
    // so a debug build links (nothing resolves them) but a release build fails
    // R8 with "Missing class okhttp3.Cache / retrofit2.Retrofit / rx.Observable".
    // Versions mirror the vendor demo's own build.gradle.
    implementation("com.squareup.okhttp3:okhttp:3.14.8")
    implementation("com.squareup.okhttp3:logging-interceptor:3.14.8")
    implementation("com.squareup.retrofit2:retrofit:2.3.0")
    implementation("com.squareup.retrofit2:converter-gson:2.3.0")
    implementation("com.squareup.retrofit2:adapter-rxjava:2.0.2")
    implementation("io.reactivex:rxjava:1.1.1")
}

flutter {
    source = "../.."
}
