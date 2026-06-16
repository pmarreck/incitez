//! Single source of truth for the embedded copyright/license notice. Imported
//! by the C FFI (lib.zig) and the WASM ABI (wasm.zig) so the identical string
//! ships in every artifact — and shows under `strings incitez.wasm`, making
//! ownership travel WITH the binary even after it's downloaded. The notice
//! summarizes the Business Source License 1.1 terms (Peter Marreck d/b/a Mecha
//! LLC) PLUS the BSD-2-Clause attribution the vendored Free Law Project data
//! requires (see LICENSE and THIRD_PARTY_LICENSES).
pub const notice: [:0]const u8 =
    "incitez © 2026 Peter Marreck (d/b/a Mecha LLC) — Business Source License 1.1. " ++
    "Source-available; non-production use plus limited production use per the " ++
    "Additional Use Grant; converts to the MIT License on 2030-06-16. See LICENSE. " ++
    "Incorporates Free Law Project data (reporters-db, courts-db) and " ++
    "eyecite-derived grammar under BSD-2-Clause; see THIRD_PARTY_LICENSES. " ++
    "https://mecha.llc";
