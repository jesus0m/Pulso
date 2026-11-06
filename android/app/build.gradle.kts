plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

android {
    namespace = "com.jesusom.pulso"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.jesusom.pulso"
        minSdk = 26
        targetSdk = 36
        // Keep in step with CFBundleShortVersionString in scripts/generate_project.py.
        versionCode = 2
        versionName = "1.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        androidResources.localeFilters += listOf("en", "es")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.01.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.12.1")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.work:work-runtime-ktx:2.10.5")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.lifecycle:lifecycle-process:2.10.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}
