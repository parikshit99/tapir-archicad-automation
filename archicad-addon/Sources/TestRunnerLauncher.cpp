#include "TestRunnerLauncher.hpp"

#include "DGModule.hpp"

#include <cstdio>
#include <cstdlib>
#include <vector>

#if defined (WINDOWS)
#pragma warning (push)
#pragma warning (disable : 4995 4091)   // as in the DevKit's Win32ShellInterface.hpp
#include <shellapi.h>
#pragma warning (pop)
#pragma comment (lib, "shell32.lib")
#endif

namespace {

const char* GuideUrl = "https://github.com/ENZYME-APD/tapir-archicad-automation/blob/main/tools/community-test-runner/GUIDE.md";
const char* AlertTitle = "Tapir Test Runner";

void OpenGuide ()
{
#if defined (WINDOWS)
    ShellExecuteW (nullptr, L"open", reinterpret_cast<LPCWSTR> (GS::UniString (GuideUrl).ToUStr ().Get ()), nullptr, nullptr, SW_SHOWNORMAL);
#else
    system (GS::UniString::Printf ("open %s", GuideUrl).ToCStr ().Get ());
#endif
}

void OfferGuide (const GS::UniString& reason)
{
    short response = DGAlert (DG_INFORMATION, AlertTitle, reason,
        "The guide shows how to download it and start it once; after that this menu opens it.",
        "Open the Guide", "Cancel");
    if (response == DG_OK) {
        OpenGuide ();
    }
}

#if defined (WINDOWS)

GS::UniString RunnerStateFolder ()
{
    const DWORD size = GetEnvironmentVariableW (L"LOCALAPPDATA", nullptr, 0);
    if (size == 0) {
        return GS::EmptyUniString;
    }
    std::vector<wchar_t> value (size);
    if (GetEnvironmentVariableW (L"LOCALAPPDATA", value.data (), size) >= size) {
        return GS::EmptyUniString;
    }
    return GS::UniString (reinterpret_cast<const GS::UniChar::Layout*> (value.data ())) + "\\TapirRunner";
}

bool FileExists (const GS::UniString& path)
{
    const DWORD attributes = GetFileAttributesW (reinterpret_cast<LPCWSTR> (path.ToUStr ().Get ()));
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// The folder the runner last ran from, as it wrote it (UTF-8, one line); empty when it never ran here
GS::UniString ReadRunnerFolder (const GS::UniString& stateFolder)
{
    const GS::UniString file = stateFolder + "\\runner_folder.txt";
    FILE* stream = _wfopen (reinterpret_cast<LPCWSTR> (file.ToUStr ().Get ()), L"rb");
    if (stream == nullptr) {
        return GS::EmptyUniString;
    }
    std::vector<char> bytes;
    char buffer[1024];
    size_t read = 0;
    while ((read = fread (buffer, 1, sizeof (buffer), stream)) > 0) {
        bytes.insert (bytes.end (), buffer, buffer + read);
    }
    fclose (stream);
    bytes.push_back ('\0');
    GS::UniString folder (bytes.data (), CC_UTF8);
    folder.Trim ();
    return folder;
}

#endif

}

void TestRunnerLauncher::Open ()
{
#if defined (WINDOWS)
    const GS::UniString stateFolder = RunnerStateFolder ();
    const GS::UniString runnerFolder = stateFolder.IsEmpty () ? GS::EmptyUniString : ReadRunnerFolder (stateFolder);
    const GS::UniString starter = runnerFolder + "\\Start Tapir Test Runner.bat";
    if (runnerFolder.IsEmpty () || !FileExists (starter)) {
        OfferGuide (runnerFolder.IsEmpty ()
            ? GS::UniString ("The Tapir test runner has not been started on this computer yet.")
            : GS::UniString::Printf ("The Tapir test runner is no longer in %T.", runnerFolder.ToPrintf ()));
        return;
    }

    // The starter finds Python, asks the setup questions the first time, then opens the runner's
    // window and closes. Its console is only worth seeing while setup asks those questions.
    const bool setUp = FileExists (stateFolder + "\\runner.json");
    const auto starterUStr = starter.ToUStr ();
    const auto folderUStr = runnerFolder.ToUStr ();
    const HINSTANCE result = ShellExecuteW (nullptr, L"open", reinterpret_cast<LPCWSTR> (starterUStr.Get ()), nullptr,
        reinterpret_cast<LPCWSTR> (folderUStr.Get ()), setUp ? SW_SHOWMINNOACTIVE : SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR> (result) <= 32) {
        DGAlert (DG_ERROR, AlertTitle, "The Tapir test runner could not be started.",
            GS::UniString::Printf ("Start it by double-clicking %T.", starter.ToPrintf ()), "OK");
    }
#else
    OfferGuide ("The Tapir test runner's window is available on Windows only.");
#endif
}
