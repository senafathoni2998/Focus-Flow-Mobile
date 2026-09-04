import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key never lives in the repository: key.properties is gitignored, written by
// hand locally and from secrets in CI. `rootProject` here is android/, not the Flutter
// project root, so this reads android/key.properties. The import above is load-bearing —
// inside an app build script `java` already names a Gradle extension, so the fully
// qualified java.util.Properties() that settings.gradle.kts gets away with fails here
// with "Unresolved reference 'util'".
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// Blank is as broken as absent, and CI writes this file from four secrets, where an unset
// secret expands to empty rather than to a missing line. Unchecked, both shapes survive
// the entire compile and then die at the very last task — a message-less
// NullPointerException, or "No key with alias ''" — neither of which names the field that
// is actually wrong.
fun keystoreProperty(name: String): String =
    keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("android/key.properties has no usable '$name'")

android {
    namespace = "com.focusflow.focusflow_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications schedules against java.time, which does not
        // exist on the older Android versions this app still supports. Desugaring
        // back-ports it; without this the build fails outright at
        // :app:checkDebugAarMetadata — and `flutter analyze` cannot see it,
        // because it is a Gradle concern, not a Dart one.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.focusflow.focusflow_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Has to stay above buildTypes: both are evaluated eagerly, in source order, so a
    // release build type that reaches for signingConfigs.getByName("release") before the
    // container is populated fails with "SigningConfig with name 'release' not found".
    // Absent key.properties the container stays empty, rather than the helper above
    // throwing on every fresh clone.
    if (keystorePropertiesFile.exists()) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperty("keyAlias")
                keyPassword = keystoreProperty("keyPassword")
                storePassword = keystoreProperty("storePassword")
                // rootProject.file, so a relative storeFile means "beside key.properties";
                // a bare file() would resolve it against android/app/ instead.
                storeFile = rootProject.file(keystoreProperty("storeFile"))
            }
        }
    }

    buildTypes {
        release {
            // Fall back to debug signing when key.properties is absent, so a fresh clone can
            // still run `flutter build apk --release` locally. CI always writes the file, so
            // CI always gets the real key — and a bundle that comes out debug-signed anyway
            // is caught by the keytool check after the build, never by trusting this line.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Supplies the back-ported java.time that core library desugaring needs.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
