# CMakeLists.txt — native macOS (Qt6) build of x2goclient.
#
# Phase 0 of the native macOS port: replaces the qmake/MacPorts/Qt4 toolchain
# for the macOS client with a modern Qt6 + CMake build producing a bundled,
# (ad-hoc or Developer-ID) signed .app.
#
# The qmake build (x2goclient.pro) remains the build system for Linux/Windows
# and the browser plugin. This file targets the macOS *client* only.
#
#   cmake -S . -B build-mac -DCMAKE_BUILD_TYPE=Release
#   cmake --build build-mac -j
#
# Toolchain assumptions (Homebrew): qt, libssh, openssl@3.

cmake_minimum_required(VERSION 3.21)

if(NOT APPLE)
    message(FATAL_ERROR
        "CMakeLists.txt currently targets the macOS client only. "
        "Use qmake (x2goclient.pro) for Linux/Windows builds.")
endif()

# --- Version (read from the VERSION file) -----------------------------------
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" X2GO_VERSION_RAW LIMIT_COUNT 1)
string(STRIP "${X2GO_VERSION_RAW}" X2GO_VERSION_RAW)
# CMake project version wants at most major.minor.patch.tweak — VERSION is e.g. 4.0.5.1
string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" X2GO_VERSION_NUMERIC "${X2GO_VERSION_RAW}")

project(x2goclient
    VERSION "${X2GO_VERSION_NUMERIC}"
    LANGUAGES CXX)

# --- macOS target settings --------------------------------------------------
# arm64-only for now. Universal2 requires a universal Qt (official online
# installer or source build); Homebrew Qt is single-arch. Override on the
# command line with -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" once a universal
# Qt is available.
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architectures" FORCE)
endif()
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "Minimum macOS version" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC_SEARCH_PATHS "${CMAKE_CURRENT_SOURCE_DIR}/src/ui")

# --- Dependencies -----------------------------------------------------------
# Qt6. qt5compat provides QRegExp/QTextCodec etc. for the Qt4->Qt6 port.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Network Svg SvgWidgets Core5Compat)
find_package(Qt6 QUIET OPTIONAL_COMPONENTS LinguistTools)

# OpenSSL (Homebrew openssl@3).
if(NOT OPENSSL_ROOT_DIR AND EXISTS "/opt/homebrew/opt/openssl@3")
    set(OPENSSL_ROOT_DIR "/opt/homebrew/opt/openssl@3")
endif()
find_package(OpenSSL REQUIRED)

# libssh (Homebrew).
find_path(LIBSSH_INCLUDE_DIR libssh/libssh.h
    PATHS /opt/homebrew/opt/libssh/include /usr/local/opt/libssh/include)
find_library(LIBSSH_LIBRARY NAMES ssh
    PATHS /opt/homebrew/opt/libssh/lib /usr/local/opt/libssh/lib)
if(NOT LIBSSH_INCLUDE_DIR OR NOT LIBSSH_LIBRARY)
    message(FATAL_ERROR "libssh not found. Install with: brew install libssh")
endif()

# System libraries / frameworks provided by macOS.
find_library(CUPS_LIBRARY cups REQUIRED)
find_library(LDAP_FRAMEWORK LDAP REQUIRED)
find_library(Z_LIBRARY z REQUIRED)

# --- Sources ----------------------------------------------------------------
set(X2GO_SOURCES
    src/sharewidget.cpp
    src/settingswidget.cpp
    src/mediawidget.cpp
    src/configwidget.cpp
    src/sessionwidget.cpp
    src/connectionwidget.cpp
    src/configdialog.cpp
    src/editconnectiondialog.cpp
    src/exportdialog.cpp
    src/imgframe.cpp
    src/LDAPSession.cpp
    src/onmainwindow.cpp
    src/sessionbutton.cpp
    src/sessionmanagedialog.cpp
    src/sshmasterconnection.cpp
    src/sshprocess.cpp
    src/SVGFrame.cpp
    src/userbutton.cpp
    src/x2gologdebug.cpp
    src/printprocess.cpp
    src/cupsprint.cpp
    src/cupsprintwidget.cpp
    src/cupsprintersettingsdialog.cpp
    src/printwidget.cpp
    src/printercmddialog.cpp
    src/printdialog.cpp
    src/wapi.cpp
    src/clicklineedit.cpp
    src/httpbrokerclient.cpp
    src/ongetpass.cpp
    src/x2gosettings.cpp
    src/brokerpassdlg.cpp
    src/contest.cpp
    src/xsettingswidget.cpp
    src/appdialog.cpp
    src/x2goutils.cpp
    src/helpdialog.cpp
    src/sessionexplorer.cpp
    src/folderbutton.cpp
    src/folderexplorer.cpp
    src/non_modal_messagebox.cpp
    src/help.cpp
    src/x2goclient.cpp
)

set(X2GO_FORMS
    src/ui/cupsprintsettingsdialog.ui
    src/ui/cupsprintwidget.ui
    src/ui/printdialog.ui
    src/ui/printercmddialog.ui
    src/ui/printwidget.ui
    src/ui/xsettingsui.ui
    src/ui/brokerpassdialog.ui
    src/ui/contest.ui
    src/ui/appdialog.ui
    src/ui/helpdialog.ui
    src/ui/folderexplorer.ui
)

# --- Qt resources -----------------------------------------------------------
# The repo's res/*.rcc files are actually .qrc XML (a historical misnomer) whose
# file paths are relative to res/. Copy them to sibling .qrc files at configure
# time so AUTORCC picks them up and the relative paths still resolve.
set(X2GO_RESOURCES)
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/res/resources.rcc"
               "${CMAKE_CURRENT_SOURCE_DIR}/res/resources.qrc" COPYONLY)
list(APPEND X2GO_RESOURCES "${CMAKE_CURRENT_SOURCE_DIR}/res/resources.qrc")

# git-info / changelog resources are only present after they are generated
# (see the gitlog/changelog step in packaging). Include them if present.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/res/txt/git-info")
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/res/git.rcc"
                   "${CMAKE_CURRENT_SOURCE_DIR}/res/git.qrc" COPYONLY)
    list(APPEND X2GO_RESOURCES "${CMAKE_CURRENT_SOURCE_DIR}/res/git.qrc")
endif()
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/res/txt/changelog")
    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/res/changelog.rcc"
                   "${CMAKE_CURRENT_SOURCE_DIR}/res/changelog.qrc" COPYONLY)
    list(APPEND X2GO_RESOURCES "${CMAKE_CURRENT_SOURCE_DIR}/res/changelog.qrc")
endif()

# --- Application bundle ------------------------------------------------------
set(MACOSX_BUNDLE_ICON "x2go-mac.icns")
set(X2GO_ICON "${CMAKE_CURRENT_SOURCE_DIR}/res/img/icons/x2go-mac.icns")

add_executable(x2goclient MACOSX_BUNDLE
    ${X2GO_SOURCES}
    ${X2GO_FORMS}
    ${X2GO_RESOURCES}
    ${X2GO_ICON}
)

# Place the icon into the bundle's Resources directory.
set_source_files_properties(${X2GO_ICON} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources")

target_compile_definitions(x2goclient PRIVATE
    CFGCLIENT
    # onmainwindow.cpp etc. still test __APPLE__ / Q_OS_DARWIN; Qt defines the
    # latter. __linux__ must NOT be defined here.
)

target_include_directories(x2goclient PRIVATE
    src
    ${LIBSSH_INCLUDE_DIR}
)

target_link_libraries(x2goclient PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Svg
    Qt6::SvgWidgets
    Qt6::Core5Compat
    OpenSSL::SSL
    OpenSSL::Crypto
    ${LIBSSH_LIBRARY}
    ${CUPS_LIBRARY}
    ${LDAP_FRAMEWORK}
    ${Z_LIBRARY}
)

# --- Info.plist -------------------------------------------------------------
set_target_properties(x2goclient PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "x2goclient"
    MACOSX_BUNDLE_GUI_IDENTIFIER "org.x2go.x2goclient"
    MACOSX_BUNDLE_BUNDLE_VERSION "${X2GO_VERSION_RAW}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${X2GO_VERSION_NUMERIC}"
    MACOSX_BUNDLE_ICON_FILE "${MACOSX_BUNDLE_ICON}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/Info.plist.in"
)

# Resolve our own @X2GO_MIN_OS@ token (CMake's bundle pass only substitutes the
# documented MACOSX_BUNDLE_* keys), then let CMake fill in the rest.
set(X2GO_MIN_OS "${CMAKE_OSX_DEPLOYMENT_TARGET}")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
               "${CMAKE_BINARY_DIR}/Info.plist.in" @ONLY)

# --- Translations -----------------------------------------------------------
# The app loads translations from the embedded resource (:/i18n/*.qm), so the
# compiled catalogs must exist in res/i18n/ *before* AUTORCC processes
# resources.qrc. Compile each .ts -> res/i18n/<base>.qm and make the target's
# autogen step depend on them. (The qt_*.qm catalogs are committed already.)
if(Qt6LinguistTools_FOUND)
    file(GLOB X2GO_TS_FILES "${CMAKE_CURRENT_SOURCE_DIR}/res/i18n/x2goclient_*.ts")
    set(X2GO_QM_FILES)
    foreach(_ts ${X2GO_TS_FILES})
        get_filename_component(_base "${_ts}" NAME_WE)
        set(_qm "${CMAKE_CURRENT_SOURCE_DIR}/res/i18n/${_base}.qm")
        add_custom_command(
            OUTPUT "${_qm}"
            COMMAND Qt6::lrelease -silent "${_ts}" -qm "${_qm}"
            DEPENDS "${_ts}"
            COMMENT "lrelease ${_base}.ts"
            VERBATIM)
        list(APPEND X2GO_QM_FILES "${_qm}")
    endforeach()
    if(X2GO_QM_FILES)
        add_custom_target(x2go_translations DEPENDS ${X2GO_QM_FILES})
        add_dependencies(x2goclient x2go_translations)
        # Ensure the .qm exist before AUTORCC embeds them.
        set_source_files_properties(${X2GO_QM_FILES} PROPERTIES GENERATED TRUE)
        set_property(TARGET x2goclient APPEND PROPERTY
            AUTOGEN_TARGET_DEPENDS ${X2GO_QM_FILES})
    endif()
endif()

# --- Code signing -----------------------------------------------------------
# Ad-hoc sign by default so the bundle runs locally on Apple Silicon (which
# requires a valid signature for arm64). Pass -DX2GO_CODESIGN_IDENTITY="Developer
# ID Application: ..." for a distributable, notarizable signature.
set(X2GO_CODESIGN_IDENTITY "-" CACHE STRING
    "codesign identity; '-' = ad-hoc, or a Developer ID Application name")
set_target_properties(x2goclient PROPERTIES
    XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "${X2GO_CODESIGN_IDENTITY}")

message(STATUS "x2goclient ${X2GO_VERSION_RAW} | arch=${CMAKE_OSX_ARCHITECTURES} | "
               "min macOS=${CMAKE_OSX_DEPLOYMENT_TARGET} | Qt ${Qt6_VERSION}")
