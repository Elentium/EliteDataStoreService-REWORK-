# Changelog

All notable changes to EliteDataStoreService are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.6.0] - 16.02.26

### Added

- **SetConstant**: New method `EliteDataStoreService:SetConstant(Constant, Value)` to configure runtime constants at runtime. Valid constants: `LOG_LEVEL`, `SHUTDOWN_YIELD`, `DEFAULT_MAX_RETRIES`, `DEFAULT_RETRIES_INTERMISSION`, `DEFAULT_EXPONENTIAL_BACKOFF`.
- **Thread reusing**: Internal processor now reuses coroutines via a dedicated thread pool instead of creating new threads per request, reducing allocation overhead.

### Changed

- Improved code quality and structure.
- Minor performance and reliability improvements.
- Fixed GetGlobalDataStore caching
- Fixed EliteDataStorePages fixed budget type -> defined budget type

---

## [1.5.0] - Previous release

### Added

- **GuardCall**: New method for safely calling methods with retry logic on failure (configurable max retries, intermission, exponential backoff).
- Logging system with configurable levels (0–3).
- Wally package support.
- Strong argument validation on all public methods.
- IntelliSense support via exported types.

### Changed

- **Breaking**: All method names simplified (removed redundant `Async` suffix, e.g. `GetAsync` → `Get`).
- **Breaking**: All DataStore request methods now return `(success, result)` — success flag first, then result or error message.
- New key locking system: allows concurrent reads when no write is active or pending; writes remain linear. Improves consistency and throughput.
- Reduced default iteration cycle from previous value to 0.35 seconds.
- Improved API documentation and inline comments.

### Notes

- The new key locking system prioritizes writes over reads during contention. If writes continuously spam requests, reads may be delayed; this is unlikely in normal usage and write budget limits mitigate prolonged spam.
