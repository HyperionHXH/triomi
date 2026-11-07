allprojects {
    repositories {
        google()
        mavenCentral()
        maven("https://www.jitpack.io") {
            content {
                includeGroup("com.github.zhanghai.quickjs-java")
                includeGroup("com.github.tachiyomiorg")
                includeGroup("com.github.mihonapp")
            }
        }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
