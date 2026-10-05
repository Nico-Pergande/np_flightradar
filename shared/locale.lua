-- Locale lookup shared by server, client and the NUI (the whole merged table is sent as `open.locale`).
--   L('squawk_set', '7000')  -> 'Squawk set to 7000'
-- Missing keys fall back to English, then to the key itself.
NpFR = NpFR or {}
Locales = Locales or {}

local merged, mergedFor = nil, nil

function NpFR.locale()
  local lang = (Config and Config.Locale) or 'en'
  if merged and mergedFor == lang then return merged end
  local out = {}
  for k, v in pairs(Locales.en or {}) do out[k] = v end
  if lang ~= 'en' then
    for k, v in pairs(Locales[lang] or {}) do out[k] = v end
  end
  merged, mergedFor = out, lang
  return out
end

function L(key, ...)
  local s = NpFR.locale()[key] or key
  if select('#', ...) > 0 then
    local ok, res = pcall(string.format, s, ...)
    if ok then return res end
  end
  return s
end
