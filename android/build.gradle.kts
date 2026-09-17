allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Plugin modules otherwise pick whatever NDK their AGP version defaults
    // to. opencv_core must build against the same NDK as the app, or its
    // C++ runtime symbols will not resolve at link time.
    plugins.withId("com.android.library") {
        extensions.findByName("android")?.withGroovyBuilder {
            setProperty("ndkVersion", "26.3.11579264")
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}


tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
