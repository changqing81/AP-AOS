pluginManagement {
    // 构建约定插件（maafw.*）在这个独立构建里，模块脚本只按 id 应用
    includeBuild("build-logic")
    repositories {
        mavenLocal()
        // KSP 的 group 是 `com.google.devtools.ksp` —— 会被下面 google 系的
        // includeGroupByRegex("com\\.google.*") 捕获，但 **Google Maven 上没有它**
        // （KSP 发布在 Maven Central / Gradle Plugin Portal）。
        // 结果：干净环境（CI）解析 plugin marker 时报
        //   Plugin [id: 'com.google.devtools.ksp', version: '2.3.9'] was not found
        // 本机因 ~/.gradle 已缓存该插件而看不出问题。
        // 这里前置一个**只服务该 group** 的 Maven Central 仓库，让 marker 必定可解析
        // （用 content 限定，不影响其它依赖的既有路由）。
        maven {
            name = "KspCentral"
            url = uri("https://repo.maven.apache.org/maven2")
            content {
                includeGroupByRegex("com\\.google\\.devtools\\.ksp")
            }
        }
        // 大陆网络环境 dl.google.com 偶发握手中断，Aliyun 镜像优先、官方源兜底
        maven {
            name = "AliyunGoogle"
            url = uri("https://maven.aliyun.com/repository/google")
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
                // 显式放行 KSP（它不在 Google Maven 上），双保险
                excludeGroupByRegex("com\\.google\\.devtools\\.ksp")
            }
        }
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
                excludeGroupByRegex("com\\.google\\.devtools\\.ksp")
            }
        }
        maven {
            name = "AliyunCentral"
            url = uri("https://maven.aliyun.com/repository/central")
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven {
            name = "AliyunGoogle"
            url = uri("https://maven.aliyun.com/repository/google")
        }
        google()
        maven {
            name = "AliyunCentral"
            url = uri("https://maven.aliyun.com/repository/central")
        }
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

rootProject.name = "MaaFwApp"
include(":app")
include(":hidden-api")
// Preferences DataStore 的 schema 代码生成（@PrefSchema / @PrefKey）
include(":annotation-api")
include(":ksp-processor")
// Semi Design 图标（vector drawable + SemiIconRes）
include(":semi-icons")
