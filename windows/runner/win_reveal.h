#ifndef RUNNER_WIN_REVEAL_H_
#define RUNNER_WIN_REVEAL_H_

#include <string>

// Open Explorer at the file's folder with the file SELECTED, robustly: uses the
// Shell API (SHParseDisplayName + SHOpenFolderAndSelectItems) so it handles
// paths with spaces and repeated calls -- unlike `explorer /select,<path>`,
// which misparses a quoted space-containing arg and falls back to Documents.
// [utf8_path] is the file's absolute path (UTF-8). No-op if it does not exist.
void RevealInExplorer(const std::string& utf8_path);

#endif  // RUNNER_WIN_REVEAL_H_
