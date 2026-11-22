require "import"
import "com.androlua.Http"
import "cjson"
import "com.androlua.LuaDialog"
import "android.widget.*"
import "android.view.*"
import "android.content.Context"
import "android.content.Intent"
import "android.net.Uri"
import "android.media.MediaPlayer"
import "android.media.PlaybackParams"
import "android.media.MediaExtractor"
import "android.media.MediaCodec"
import "android.media.MediaFormat"
import "android.util.Base64"
import "android.os.*"
import "android.graphics.Typeface"
import "android.graphics.drawable.GradientDrawable"
import "android.graphics.Color"
import "java.io.*"
import "java.nio.channels.Channels"
import "java.util.HashMap"
import "java.util.Locale"
import "java.util.zip.ZipInputStream"
import "android.speech.tts.TextToSpeech"
import "android.app.AlertDialog"
import "android.content.DialogInterface"
import "android.provider.MediaStore"
import "android.content.ContentValues"
import "android.content.pm.PackageManager"
import "android.Manifest"
import "android.os.Environment"
import "android.view.inputmethod.EditorInfo"
import "android.view.inputmethod.InputMethodManager"
import "android.text.InputType"

local context = activity or service
local mainHandler = Handler(Looper.getMainLooper())
local tts = nil
local mainDialog = nil

local savedText = ""
local savedFileName = ""
local isGenerating = false
local currentGenerateBtn = nil
local currentPlayBtn = nil
local currentResultLayout = nil
local currentProgressText = nil

local currentSpeedValue = 1.0
local selectedVoice = "Puck"
local selectedVoice2 = "Kore"
local isPodcastMode = false
local isMusicMode = false
local isSfxMode = false
local isAudioSfxMode = false
local selectedInputAudioPath = ""
local selectedInputAudioUri = nil
local selectedInputAudioName = ""
local selectedInputAudioDurMs = 0
local podcastGenerationMode = 1
local generatedAudioPath = nil
local mediaPlayer = nil
local isPlaying = false
local currentHttpRequest = nil

local appHidden = false
local hiddenGenerating = false

local SFX_PACK_ZIP_URL = ""

local selectedMusicStyle = "Romantic Guitar"
local MUSIC_STYLES = {"Romantic Guitar", "Emotional Sad Piano", "Fast Pop Beats", "Soft Acoustic Vibe"}
local maleVoiceForMusic = "Puck"
local femaleVoiceForMusic = "Kore"

local EMOTIONS = {
    "Auto (Smart Emotion)", "Neutral", "Happy", "Sad", "Angry", "Excited", "Fearful",
    "News Anchor", "Narrator", "Formal", "Casual", "Friendly", "Cheerful",
    "Hopeful", "Playful", "Romantic", "Loving", "Gentle", "Humble", "Innocent",
    "Calm", "Confident", "Proud", "Strong", "Bold", "Passionate", "Gloomy",
    "Desperate", "Shy", "Bored", "Surprised", "Sarcastic", "Storytelling",
    "Dramatic", "Energetic", "Funny", "Mysterious", "Serious", "Whisper", "Fast", "Slow"
}
local selectedEmotion = "Auto (Smart Emotion)"

pcall(function()
    Http.setConnTimeout(120000)
    Http.setReadTimeout(120000)
end)

local VOICE_LIST = {
    "Puck", "Kore", "Charon", "Zephyr", "Fenrir", "Leda",
    "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
    "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
    "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima"
}

local SPEED_LIST = {"1.0x", "1.25x", "1.5x", "1.75x", "2.0x"}
local SPEED_VALUES = {1.0, 1.25, 1.5, 1.75, 2.0}

local DEFAULT_TTS_MODEL = "gemini-2.5-flash-preview-tts"
local selectedModel = DEFAULT_TTS_MODEL
local userText = ""
local userFileName = ""

local MAX_CHARS = 500000
local PREFS_NAME = "Gemini_AudioCraft_Prefs"
local prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

-- ===== BASIC UTILITIES =====
function runOnUi(callback) mainHandler.post(Runnable({ run = callback })) end
function delay(ms, callback) Handler(Looper.getMainLooper()).postDelayed(Runnable({ run = callback }), ms) end
function showToast(msg) runOnUi(function() Toast.makeText(context, tostring(msg), Toast.LENGTH_LONG).show() end) end
function vibrate(ms)
    local vibrator = context.getSystemService(Context.VIBRATOR_SERVICE)
    if vibrator then pcall(function() vibrator.vibrate(ms or 50) end) end
end

local function cleanApiKey(rawKey)
    if not rawKey then return "" end
    local k = tostring(rawKey):gsub("[^%w%-%_%.]", "")
    if k:sub(1, 4) == "AQAb" then
        k = "AQ." .. k:sub(3)
    end
    return k
end

local function isValidVoice(vName)
    for _, v in ipairs(VOICE_LIST) do
        if v == vName then return true end
    end
    return false
end

local VOICE_GENDER_MAP = {
    Puck = "male", Charon = "male", Fenrir = "male", Orus = "male",
    Enceladus = "male", Iapetus = "male", Umbriel = "male", Algieba = "male",
    Algenib = "male", Rasalgethi = "male", Alnilam = "male", Schedar = "male",
    Kore = "female", Zephyr = "female", Leda = "female", Aoede = "female",
    Callirrhoe = "female", Autonoe = "female", Despina = "female", Erinome = "female",
    Laomedeia = "female", Achernar = "female", Gacrux = "female", Pulcherrima = "female"
}

local function getVoiceGenderLabel(vName)
    return VOICE_GENDER_MAP[vName] or "male"
end

local function isValidEmotion(eName)
    for _, e in ipairs(EMOTIONS) do
        if e == eName then return true end
    end
    return false
end

local function extractApiError(code, content)
    if content and type(content) == "string" and #content > 0 then
        local retryTag = ""
        local rawMin, rawSec = content:match("retry in (%d+)m([%d%.]+)s")
        if rawMin and rawSec then
            local totalS = math.ceil(tonumber(rawMin) * 60 + tonumber(rawSec))
            retryTag = " [retry in " .. tostring(totalS) .. "s]"
        else
            local secStr = content:match("retry in ([%d%.]+)s")
                or content:match('"retryDelay"%s*:%s*"([%d%.]+)s"')
                or content:match("retryDelay[^%d]*([%d%.]+)")
            if secStr then
                local totalS = math.ceil(tonumber(secStr) or 0)
                if totalS > 0 then
                    retryTag = " [retry in " .. tostring(totalS) .. "s]"
                end
            end
        end
        local ok, data = pcall(cjson.decode, content)
        if ok and data and data.error and data.error.message then
            local msg = tostring(data.error.message)
            if #msg > 95 then msg = msg:sub(1, 95) .. "..." end
            return "HTTP " .. tostring(code) .. ": " .. msg .. retryTag
        end
        return "HTTP " .. tostring(code) .. retryTag
    end
    return "HTTP " .. tostring(code)
end

-- ===== CLEAN SINGLE-VIEW LIVE PROGRESS (1% TO 100%) =====
local progressPercent = 0
local progressTarget = 92
local progressTimerRunning = false
local progressHandler = Handler(Looper.getMainLooper())
local progressRunnable = nil

local function renderProgressValue()
    runOnUi(function()
        local pct = math.max(1, math.min(100, math.floor(progressPercent)))
        if currentProgressText then
            currentProgressText.setVisibility(View.VISIBLE)
            currentProgressText.setText(pct .. "%")
        end
    end)
end

local function scheduleNextProgressTick()
    if not progressTimerRunning or not isGenerating then return end
    local gap = progressTarget - progressPercent
    local tickDelay = (gap > 8) and 140 or ((gap > 2) and 380 or 750)
    progressRunnable = Runnable({
        run = function()
            if not progressTimerRunning or not isGenerating then return end
            if progressPercent < progressTarget then
                progressPercent = progressPercent + 1
                renderProgressValue()
            end
            scheduleNextProgressTick()
        end
    })
    progressHandler.postDelayed(progressRunnable, tickDelay)
end

function startProgressBar(initialTarget)
    if progressRunnable then
        pcall(function() progressHandler.removeCallbacks(progressRunnable) end)
    end
    progressPercent = 1
    progressTarget = initialTarget or 92
    progressTimerRunning = true
    runOnUi(function()
        if currentGenerateBtn then
            currentGenerateBtn.setText("GENERATING, PLEASE WAIT...")
        end
    end)
    renderProgressValue()
    scheduleNextProgressTick()
end

function setProgressRange(minPct, maxPct)
    if minPct and minPct > progressPercent then
        progressPercent = math.min(98, math.floor(minPct))
    end
    if maxPct then
        progressTarget = math.min(99, math.max(progressPercent + 1, math.floor(maxPct)))
    end
    renderProgressValue()
end

function finishProgressAndRun(onFinishedCallback)
    progressTimerRunning = false
    if progressRunnable then
        pcall(function() progressHandler.removeCallbacks(progressRunnable) end)
        progressRunnable = nil
    end
    local function fastFinishStep()
        if progressPercent < 100 then
            progressPercent = math.min(100, progressPercent + 3)
            renderProgressValue()
            progressHandler.postDelayed(Runnable({ run = fastFinishStep }), 18)
        else
            renderProgressValue()
            delay(180, function()
                if currentProgressText and not isGenerating then
                    currentProgressText.setVisibility(View.GONE)
                end
                if onFinishedCallback then onFinishedCallback() end
            end)
        end
    end
    fastFinishStep()
end

function stopProgressBar()
    progressTimerRunning = false
    if progressRunnable then
        pcall(function() progressHandler.removeCallbacks(progressRunnable) end)
        progressRunnable = nil
    end
    runOnUi(function()
        if currentProgressText then
            currentProgressText.setVisibility(View.GONE)
        end
    end)
end

-- ===== MULTI API KEY SYSTEM =====
local apiKeys = {}
local currentApiKeyIndex = 1
local googleApiKey = ""
local rawKey1, rawKey2, rawKey3 = "", "", ""

local function loadApiKeys()
    apiKeys = {}
    local k1 = cleanApiKey(prefs.getString("apikey1", ""))
    local k2 = cleanApiKey(prefs.getString("apikey2", ""))
    local k3 = cleanApiKey(prefs.getString("apikey3", ""))
    local oldK = cleanApiKey(prefs.getString("apikey", ""))
    if k1 == "" and oldK ~= "" then k1 = oldK end
    rawKey1, rawKey2, rawKey3 = k1, k2, k3
    if k1 ~= "" then table.insert(apiKeys, k1) end
    if k2 ~= "" then table.insert(apiKeys, k2) end
    if k3 ~= "" then table.insert(apiKeys, k3) end
    currentApiKeyIndex = 1
    googleApiKey = apiKeys[1] or ""
end

local function getCurrentApiKey()
    if #apiKeys == 0 then return "" end
    if currentApiKeyIndex > #apiKeys then currentApiKeyIndex = 1 end
    return apiKeys[currentApiKeyIndex] or ""
end

local function switchToNextApiKey()
    if #apiKeys <= 1 then return false end
    currentApiKeyIndex = currentApiKeyIndex + 1
    if currentApiKeyIndex > #apiKeys then currentApiKeyIndex = 1 end
    googleApiKey = apiKeys[currentApiKeyIndex] or ""
    return true
end

local function saveApiKeysToPrefs(k1, k2, k3)
    local editor = prefs.edit()
    if k1 ~= nil then rawKey1 = cleanApiKey(k1) end
    if k2 ~= nil then rawKey2 = cleanApiKey(k2) end
    if k3 ~= nil then rawKey3 = cleanApiKey(k3) end
    editor.putString("apikey1", rawKey1 or "")
    editor.putString("apikey2", rawKey2 or "")
    editor.putString("apikey3", rawKey3 or "")
    editor.putString("apikey", rawKey1 or "")
    editor.apply()
end

-- ===== UI HELPERS =====
function createGradientDrawable(startColor, endColor, cornerRadius, strokeColor, strokeWidth)
    local gradient = GradientDrawable(GradientDrawable.Orientation.TL_BR, {
        tonumber(startColor:gsub("#", "0x")),
        tonumber(endColor:gsub("#", "0x"))
    })
    gradient.setCornerRadius(cornerRadius)
    if strokeColor and strokeWidth then
        gradient.setStroke(strokeWidth, tonumber(strokeColor:gsub("#", "0x")))
    end
    return gradient
end

function createCardDrawable(bgColor, cornerRadius, strokeColor, strokeWidth)
    local shape = GradientDrawable()
    shape.setColor(tonumber(bgColor:gsub("#", "0x")))
    shape.setCornerRadius(cornerRadius)
    if strokeColor and strokeWidth then
        shape.setStroke(strokeWidth, tonumber(strokeColor:gsub("#", "0x")))
    end
    return shape
end

function initTTS()
    if tts == nil then
        tts = TextToSpeech(context, TextToSpeech.OnInitListener({
            onInit = function(status)
                if status == TextToSpeech.SUCCESS then
                    pcall(function() tts.setLanguage(Locale.US) end)
                end
            end
        }))
    end
end

function speakFeedback(message)
    initTTS()
    pcall(function() if tts then tts.speak(message, TextToSpeech.QUEUE_FLUSH, nil) end end)
end

function deleteOldAudioFile()
    if generatedAudioPath then
        pcall(function()
            local f = File(generatedAudioPath)
            if f.exists() then f.delete() end
        end)
        generatedAudioPath = nil
    end
end

function closeAndCleanup()
    stopProgressBar()
    if currentHttpRequest ~= nil then
        pcall(function() currentHttpRequest.cancel() end)
        currentHttpRequest = nil
    end
    if mediaPlayer ~= nil then
        pcall(function()
            if mediaPlayer.isPlaying() then mediaPlayer.stop() end
            mediaPlayer.release()
        end)
        mediaPlayer = nil
        isPlaying = false
    end
    deleteOldAudioFile()
    if tts then
        pcall(function() tts.stop() tts.shutdown() end)
        tts = nil
    end
end

function saveSettings()
    local editor = prefs.edit()
    editor.putString("voice", selectedVoice)
    editor.putString("voice2", selectedVoice2)
    editor.putBoolean("podcastMode", isPodcastMode)
    editor.putBoolean("musicMode", isMusicMode)
    editor.putBoolean("sfxMode", isSfxMode)
    editor.putBoolean("audioSfxMode", isAudioSfxMode)
    editor.putString("model", DEFAULT_TTS_MODEL)
    editor.putString("filename", userFileName)
    editor.putString("musicStyle", selectedMusicStyle)
    editor.putString("emotion", selectedEmotion)
    editor.putInt("podcast_gen_mode", podcastGenerationMode)
    editor.apply()
    saveApiKeysToPrefs()
end

function loadSettings()
    selectedVoice = prefs.getString("voice", "Puck")
    if not isValidVoice(selectedVoice) then selectedVoice = "Puck" end
    selectedVoice2 = prefs.getString("voice2", "Kore")
    if not isValidVoice(selectedVoice2) then selectedVoice2 = "Kore" end
    isPodcastMode = prefs.getBoolean("podcastMode", false)
    isMusicMode = prefs.getBoolean("musicMode", false)
    isSfxMode = prefs.getBoolean("sfxMode", false)
    isAudioSfxMode = prefs.getBoolean("audioSfxMode", false)
    selectedModel = DEFAULT_TTS_MODEL
    userFileName = prefs.getString("filename", "")
    selectedMusicStyle = prefs.getString("musicStyle", "Romantic Guitar")
    selectedEmotion = prefs.getString("emotion", "Auto (Smart Emotion)")
    if not isValidEmotion(selectedEmotion) then selectedEmotion = "Auto (Smart Emotion)" end
    podcastGenerationMode = prefs.getInt("podcast_gen_mode", 1)
    loadApiKeys()
end

function applyPlaybackSpeed()
    if mediaPlayer and isPlaying and Build.VERSION.SDK_INT >= 23 then
        pcall(function()
            if mediaPlayer.isPlaying() then
                local lp = PlaybackParams()
                lp.setSpeed(currentSpeedValue)
                mediaPlayer.setPlaybackParams(lp)
            end
        end)
    end
end

function initMediaPlayer()
    if mediaPlayer ~= nil then
        if isPlaying then pcall(function() mediaPlayer.stop() end) end
        pcall(function() mediaPlayer.release() end)
        isPlaying = false
    end
    mediaPlayer = MediaPlayer()
    mediaPlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener({
        onCompletion = function(mp)
            isPlaying = false
            if currentPlayBtn then runOnUi(function() currentPlayBtn.setText("PLAY") end) end
        end
    }))
end

function togglePlayPause(playBtn)
    if mediaPlayer == nil then showToast("No audio loaded") return false end
    if isPlaying then
        pcall(function() mediaPlayer.pause() end)
        isPlaying = false
        runOnUi(function() playBtn.setText("PLAY") end)
    else
        pcall(function()
            mediaPlayer.start()
            applyPlaybackSpeed()
            isPlaying = true
            runOnUi(function() playBtn.setText("PAUSE") end)
        end)
    end
    return true
end

function jumpAudio(seconds)
    if mediaPlayer then
        pcall(function()
            local currentPos = mediaPlayer.getCurrentPosition()
            local duration = mediaPlayer.getDuration()
            local newPos = currentPos + (seconds * 1000)
            if newPos < 0 then newPos = 0 end
            if newPos > duration then newPos = duration end
            mediaPlayer.seekTo(newPos)
            showToast((seconds > 0 and "Forward " or "Rewind ") .. math.abs(seconds) .. "s")
        end)
    end
end

function writeWavHeader(outStream, totalAudioLen, sampleRate, numChannels)
    local sRate = math.floor(tonumber(sampleRate) or 24000)
    local channels = math.floor(tonumber(numChannels) or 1)
    local audioLen = math.floor(tonumber(totalAudioLen) or 0)
    local bitsPerSample = 16
    local byteRate = math.floor(sRate * channels * 2)
    local blockAlign = math.floor(channels * 2)
    local totalSize = math.floor(audioLen + 36)

    local function writeShort(stream, val)
        local v = math.floor(tonumber(val) or 0)
        stream.write(v & 0xFF)
        stream.write((v >> 8) & 0xFF)
    end
    local function writeInt(stream, val)
        local v = math.floor(tonumber(val) or 0)
        stream.write(v & 0xFF)
        stream.write((v >> 8) & 0xFF)
        stream.write((v >> 16) & 0xFF)
        stream.write((v >> 24) & 0xFF)
    end

    outStream.write(0x52); outStream.write(0x49); outStream.write(0x46); outStream.write(0x46)
    writeInt(outStream, totalSize)
    outStream.write(0x57); outStream.write(0x41); outStream.write(0x56); outStream.write(0x45)
    outStream.write(0x66); outStream.write(0x6D); outStream.write(0x74); outStream.write(0x20)
    writeInt(outStream, 16)
    writeShort(outStream, 1)
    writeShort(outStream, channels)
    writeInt(outStream, sRate)
    writeInt(outStream, byteRate)
    writeShort(outStream, blockAlign)
    writeShort(outStream, bitsPerSample)
    outStream.write(0x64); outStream.write(0x61); outStream.write(0x74); outStream.write(0x61)
    writeInt(outStream, audioLen)
end

-- ===== DOWNLOAD (ALL ANDROID VERSIONS) =====
local function hasStoragePermission()
    if Build.VERSION.SDK_INT >= 23 then
        local granted = context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        return granted == PackageManager.PERMISSION_GRANTED
    end
    return true
end

local function requestStoragePermission()
    if Build.VERSION.SDK_INT >= 23 and activity then
        activity.requestPermissions({Manifest.permission.WRITE_EXTERNAL_STORAGE}, 1001)
    end
end

function downloadWithCurrentSpeed()
    if not generatedAudioPath then showToast("Generate audio first") return false end
    local srcFile = File(generatedAudioPath)
    if not srcFile.exists() or srcFile.length() <= 44 then
        showToast("Audio file missing, please regenerate")
        return false
    end

    local rawBase = (userFileName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    rawBase = rawBase:gsub("[/\\:*?\"<>|%c]+", "_"):gsub("%s+", "_")
    if rawBase == "" then rawBase = "AudioCraft_" .. os.time() end
    local fileName = rawBase:find("%.wav$") and rawBase or (rawBase .. ".wav")

    -- Tier 1: Direct write to /storage/emulated/0/Download (fastest & works on all Jieshuo devices with storage access)
    local okDirect = pcall(function()
        local dlDir = File("/storage/emulated/0/Download")
        if not dlDir.exists() then dlDir.mkdirs() end
        local dest = File(dlDir, fileName)
        local fis = FileInputStream(srcFile)
        local fos = FileOutputStream(dest)
        local buf = byte[8192]
        while true do
            local len = fis.read(buf)
            if len == -1 then break end
            fos.write(buf, 0, len)
        end
        fis.close()
        fos.close()
        if dest.exists() and dest.length() > 44 then
            pcall(function()
                local intent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
                intent.setData(Uri.fromFile(dest))
                context.sendBroadcast(intent)
            end)
        else
            error("Empty output")
        end
    end)
    if okDirect then
        showToast("Saved to Download: " .. fileName)
        speakFeedback("Download complete")
        return true
    end

    -- Tier 2: Android 10+ MediaStore.Downloads (official Scoped Storage Downloads URI)
    if Build.VERSION.SDK_INT >= 29 then
        local okMsDl = pcall(function()
            local resolver = context.getContentResolver()
            local cv = ContentValues()
            cv.put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            cv.put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
            cv.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            local uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv)
            if not uri then error("Insert returned nil") end
            local out = resolver.openOutputStream(uri)
            local fis = FileInputStream(srcFile)
            local buf = byte[8192]
            while true do
                local len = fis.read(buf)
                if len == -1 then break end
                out.write(buf, 0, len)
            end
            fis.close()
            out.close()
        end)
        if okMsDl then
            showToast("Saved to Download: " .. fileName)
            speakFeedback("Download complete")
            return true
        end

        -- Tier 3: Android 10+ MediaStore.Audio in Music/Gemini_AudioCraft (always allowed by Scoped Storage)
        local okMsMusic = pcall(function()
            local resolver = context.getContentResolver()
            local cv = ContentValues()
            cv.put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            cv.put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
            cv.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC .. "/Gemini_AudioCraft")
            local uri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, cv)
            if not uri then error("Music insert returned nil") end
            local out = resolver.openOutputStream(uri)
            local fis = FileInputStream(srcFile)
            local buf = byte[8192]
            while true do
                local len = fis.read(buf)
                if len == -1 then break end
                out.write(buf, 0, len)
            end
            fis.close()
            out.close()
        end)
        if okMsMusic then
            showToast("Saved to Music/Gemini_AudioCraft: " .. fileName)
            speakFeedback("Download complete")
            return true
        end
    end

    -- Tier 4: App External Downloads folder (requires zero permissions on all Android versions)
    local savedPath = nil
    local okExt = pcall(function()
        local extDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        if not extDir then extDir = context.getCacheDir() end
        if not extDir.exists() then extDir.mkdirs() end
        local fallback = File(extDir, fileName)
        local fis = FileInputStream(srcFile)
        local fos = FileOutputStream(fallback)
        local buf = byte[8192]
        while true do
            local len = fis.read(buf)
            if len == -1 then break end
            fos.write(buf, 0, len)
        end
        fis.close()
        fos.close()
        savedPath = fallback.getAbsolutePath()
    end)
    if okExt and savedPath then
        showToast("Saved: " .. savedPath)
        speakFeedback("Download complete")
        return true
    end

    showToast("Download failed")
    return false
end

-- ===== SMART SENTENCE EMOTION & EXPRESSIVE PROMPT SYSTEM =====
local EMOTION_PREFIXES = {
    ["Neutral"] = "Speak in a natural, clear tone: ",
    ["Happy"] = "Speak in a happy, cheerful tone: ",
    ["Sad"] = "Speak in a sad, emotional, melancholic tone: ",
    ["Angry"] = "Speak in an angry, forceful tone: ",
    ["Excited"] = "Speak in an excited, energetic tone: ",
    ["Fearful"] = "Speak in a tense, hushed, fearful tone: ",
    ["News Anchor"] = "Speak like a professional news anchor: ",
    ["Narrator"] = "Speak like a calm, expressive storyteller: ",
    ["Formal"] = "Speak in a formal, official tone: ",
    ["Casual"] = "Speak in a casual, informal tone: ",
    ["Friendly"] = "Speak in a warm, friendly tone: ",
    ["Cheerful"] = "Speak cheerfully: ",
    ["Hopeful"] = "Speak hopefully: ",
    ["Playful"] = "Speak playfully: ",
    ["Romantic"] = "Speak romantically: ",
    ["Loving"] = "Speak lovingly: ",
    ["Gentle"] = "Speak gently: ",
    ["Humble"] = "Speak humbly: ",
    ["Innocent"] = "Speak innocently: ",
    ["Calm"] = "Speak calmly: ",
    ["Confident"] = "Speak confidently: ",
    ["Proud"] = "Speak proudly: ",
    ["Strong"] = "Speak strongly: ",
    ["Bold"] = "Speak boldly: ",
    ["Passionate"] = "Speak passionately: ",
    ["Gloomy"] = "Speak gloomily: ",
    ["Desperate"] = "Speak earnestly: ",
    ["Shy"] = "Speak softly: ",
    ["Bored"] = "Speak in a bored tone: ",
    ["Surprised"] = "Speak with surprise: ",
    ["Sarcastic"] = "Speak sarcastically: ",
    ["Storytelling"] = "Speak like an engaging audiobook narrator: ",
    ["Dramatic"] = "Speak dramatically: ",
    ["Energetic"] = "Speak energetically: ",
    ["Funny"] = "Speak humorously: ",
    ["Mysterious"] = "Speak mysteriously: ",
    ["Serious"] = "Speak seriously: ",
    ["Whisper"] = "Whisper softly: ",
    ["Fast"] = "Speak briskly: ",
    ["Slow"] = "Speak slowly: "
}

-- ===== SMART SEQUENTIAL API FAILOVER (API 1 -> API 2 -> API 3) + PAUSE/RESUME QUOTA GUARD =====
local deadApiKeys = {}
local quotaExhaustedKeys = {}
local quotaPauseDialog = nil
local quotaCountdownHandler = nil
local quotaCountdownRunnable = nil

local function resetApiFailoverState()
    deadApiKeys = {}
    quotaExhaustedKeys = {}
    currentApiKeyIndex = 1
    silentAutoRetryMode = false
    consecutiveQuotaPauses = 0
end

local function markCurrentKeyDeadIfInvalid(httpCode, errMsg)
    local curKey = getCurrentApiKey()
    if not curKey or curKey == "" then return end
    local msg = tostring(errMsg or ""):lower()
    if httpCode == 401 or httpCode == 403 or (httpCode == 400 and (msg:find("api_key_invalid") or msg:find("key not valid") or msg:find("invalid argument") or msg:find("expired"))) then
        deadApiKeys[curKey] = true
    elseif httpCode == 429 or msg:find("quota") or msg:find("resource_exhausted") or msg:find("rate limit") then
        quotaExhaustedKeys[curKey] = true
    end
end

-- Switches sequentially to the next available API key (API 1 -> API 2 -> API 3).
-- Returns true if a fresh key is available, or false when ALL configured keys are exhausted/invalid.
local function switchToNextValidApiKey()
    if #apiKeys <= 1 then return false end
    local startIdx = currentApiKeyIndex
    for step = 1, #apiKeys - 1 do
        local candIdx = ((startIdx + step - 1) % #apiKeys) + 1
        local candidate = apiKeys[candIdx]
        if candidate and candidate ~= "" and not deadApiKeys[candidate] and not quotaExhaustedKeys[candidate] then
            currentApiKeyIndex = candIdx
            runOnUi(function()
                showToast("Switched to API Key #" .. tostring(currentApiKeyIndex))
            end)
            return true
        end
    end
    return false
end

local consecutiveQuotaPauses = 0

local function parseRetryAfterSec(errMsg)
    local msg = tostring(errMsg or "")
    local baseSec = nil
    local mStr, sStr = msg:match("retry in (%d+)m([%d%.]+)s")
    if mStr and sStr then
        baseSec = math.ceil(tonumber(mStr) * 60 + tonumber(sStr))
    else
        local secStr = msg:match("retry in ([%d%.]+)s") or msg:match("retryDelay[^%d]*([%d%.]+)")
        if secStr then
            baseSec = tonumber(secStr)
        end
    end
    -- Always add a +10s safety buffer above Google's exact retryDelay (and minimum 68s for 60s RPM sliding window)
    local waitSec = 68
    if baseSec and baseSec > 0 then
        if baseSec < 15 then
            waitSec = 68
        elseif baseSec <= 300 then
            waitSec = math.ceil(baseSec + 10)
        else
            waitSec = 180
        end
    end
    -- If the same part hit quota back-to-back, add extra cooldown so the very next resume succeeds cleanly
    if consecutiveQuotaPauses > 0 then
        waitSec = math.min(180, waitSec + (consecutiveQuotaPauses * 22))
    end
    return waitSec
end

local function parseRetryAfterMs(errMsg, attemptNum)
    return parseRetryAfterSec(errMsg) * 1000
end

local function cancelQuotaCountdown()
    if quotaCountdownHandler and quotaCountdownRunnable then
        pcall(function() quotaCountdownHandler.removeCallbacks(quotaCountdownRunnable) end)
    end
    quotaCountdownRunnable = nil
    if quotaPauseDialog then
        pcall(function() quotaPauseDialog.dismiss() end)
        quotaPauseDialog = nil
    end
end

-- Inline Quick API Key Updater (never closes mainDialog or discards generated audio!)
local function showQuickApiUpdateDialog(onKeysUpdated)
    runOnUi(function()
        loadApiKeys()
        local qViews = {}
        local qLayout = {
            LinearLayout, orientation = "vertical", padding = "22dp", layout_width = "fill", layout_height = "wrap", id = "quickApiCard",
            { TextView, text = "Update API Keys", textSize = 18, textColor = "#00E5FF", gravity = "center", paddingBottom = "12dp", typeface = Typeface.DEFAULT_BOLD },
            { TextView, text = "Add a fresh API key below and tap SAVE & RESUME to continue from where audio paused.", textSize = 13, textColor = "#CCCCCC", gravity = "center", paddingBottom = "14dp" },
            { EditText, id = "qKey1", hint = "API Key 1", layout_width = "fill", layout_height = "wrap", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF", layout_marginBottom = "10dp" },
            { EditText, id = "qKey2", hint = "API Key 2 (Optional)", layout_width = "fill", layout_height = "wrap", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF", layout_marginBottom = "10dp" },
            { EditText, id = "qKey3", hint = "API Key 3 (Optional)", layout_width = "fill", layout_height = "wrap", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF", layout_marginBottom = "16dp" },
            {
                LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap",
                { Button, id = "qSaveBtn", text = "SAVE AND RESUME", layout_width = "0dp", layout_weight = "1.4", textColor = "#FFFFFF", padding = "13dp", layout_marginRight = "6dp", typeface = Typeface.DEFAULT_BOLD },
                { Button, id = "qCancelBtn", text = "CANCEL", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "13dp", typeface = Typeface.DEFAULT_BOLD }
            }
        }
        local qDlg = LuaDialog(context)
        qDlg.setCancelable(false)
        qDlg.setView(loadlayout(qLayout, qViews))
        pcall(function()
            qViews.quickApiCard.setBackground(createGradientDrawable("#071324", "#102542", 24, "#00E5FF", 3))
            qViews.qKey1.setBackground(createCardDrawable("#081528", 12, "#FF4D6D", 1))
            qViews.qKey2.setBackground(createCardDrawable("#081528", 12, "#2ECC71", 1))
            qViews.qKey3.setBackground(createCardDrawable("#081528", 12, "#3498DB", 1))
            qViews.qSaveBtn.setBackground(createGradientDrawable("#27AE60", "#1E8449", 18, "#A9DFBF", 1))
            qViews.qCancelBtn.setBackground(createGradientDrawable("#576574", "#222F3E", 18, "#8395A7", 1))
        end)
        qViews.qKey1.setText(rawKey1 or "")
        qViews.qKey2.setText(rawKey2 or "")
        qViews.qKey3.setText(rawKey3 or "")

        qViews.qSaveBtn.onClick = function()
            vibrate(30)
            local nk1 = cleanApiKey(qViews.qKey1.getText().toString())
            local nk2 = cleanApiKey(qViews.qKey2.getText().toString())
            local nk3 = cleanApiKey(qViews.qKey3.getText().toString())
            if nk1 == "" and nk2 == "" and nk3 == "" then
                showToast("Enter at least one API key")
                return
            end
            saveApiKeysToPrefs(nk1, nk2, nk3)
            resetApiFailoverState()
            qDlg.dismiss()
            showToast("API keys updated! Resuming...")
            if onKeysUpdated then onKeysUpdated() end
        end

        qViews.qCancelBtn.onClick = function()
            vibrate(25)
            qDlg.dismiss()
        end

        qDlg.show()
    end)
end

-- Alert Dialog when ALL configured API keys hit their quota or expire:
-- Preserves 100% of generated audio so far, auto-resumes after quota cooldown, OR lets user add a new API key / save partial audio!
local silentAutoRetryMode = false

local function showApiQuotaPausedDialog(doneCount, totalCount, errReason, onResumeCallback, onSavePartialCallback)
    runOnUi(function()
        cancelQuotaCountdown()
        local waitSec = parseRetryAfterSec(errReason)
        consecutiveQuotaPauses = consecutiveQuotaPauses + 1
        local remaining = waitSec
        local keyTotal = math.max(1, #apiKeys)

        -- If plugin is hidden in background OR user already tapped RESUME once, wait & auto-resume SILENTLY with zero popup!
        if appHidden or silentAutoRetryMode then
            showToast("API limit reached — auto-resuming silently in " .. tostring(waitSec) .. "s...")
            quotaCountdownHandler = Handler(Looper.getMainLooper())
            quotaCountdownRunnable = Runnable({
                run = function()
                    quotaCountdownRunnable = nil
                    quotaExhaustedKeys = {}
                    currentApiKeyIndex = 1
                    if onResumeCallback then onResumeCallback() end
                end
            })
            quotaCountdownHandler.postDelayed(quotaCountdownRunnable, waitSec * 1000)
            return
        end

        local pViews = {}
        local pLayout = {
            LinearLayout, orientation = "vertical", padding = "22dp", layout_width = "fill", layout_height = "wrap", id = "pauseCard",
            {
                LinearLayout, orientation = "vertical", padding = "14dp", layout_width = "fill", layout_height = "wrap", id = "pauseHeaderBox", layout_marginBottom = "14dp",
                { TextView, id = "pauseTitle", text = "All API Keys Limit Reached", textSize = 18, textColor = "#F1C40F", gravity = "center", typeface = Typeface.DEFAULT_BOLD }
            },
            {
                LinearLayout, orientation = "vertical", padding = "14dp", layout_width = "fill", layout_height = "wrap", id = "pauseInfoBox", layout_marginBottom = "16dp",
                { TextView, id = "pauseBody", text = "", textSize = 14, textColor = "#FFFFFF", gravity = "center" }
            },
            { Button, id = "addApiResumeBtn", text = "ADD NEW API", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "13dp", layout_marginBottom = "8dp", typeface = Typeface.DEFAULT_BOLD },
            {
                LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap",
                { Button, id = "resumeNowBtn", text = "RESUME NOW", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "13dp", layout_marginRight = "6dp", typeface = Typeface.DEFAULT_BOLD },
                { Button, id = "savePartialBtn", text = "LISTEN SO FAR", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "13dp", typeface = Typeface.DEFAULT_BOLD }
            }
        }

        local pDlg = LuaDialog(context)
        pDlg.setCancelable(false)
        pDlg.setView(loadlayout(pLayout, pViews))
        quotaPauseDialog = pDlg

        pcall(function()
            pViews.pauseCard.setBackground(createGradientDrawable("#1A0F2E", "#2D164A", 24, "#F1C40F", 3))
            pViews.pauseHeaderBox.setBackground(createCardDrawable("#261442", 16, "#F1C40F", 2))
            pViews.pauseInfoBox.setBackground(createCardDrawable("#140B24", 16, "#A29BFE", 1))
            pViews.addApiResumeBtn.setBackground(createGradientDrawable("#2980B9", "#1F618D", 18, "#85C1E9", 1))
            pViews.resumeNowBtn.setBackground(createGradientDrawable("#27AE60", "#1E8449", 18, "#A9DFBF", 1))
            pViews.savePartialBtn.setBackground(createGradientDrawable("#D35400", "#A04000", 18, "#F5CBA7", 1))
        end)

        local function updateMsg()
            local txt = "All " .. tostring(keyTotal) .. " API key(s) reached their quota or expired.\n\n"
                .. "Your generated audio (" .. tostring(doneCount) .. "/" .. tostring(totalCount) .. " parts) is safely kept.\n"
                .. "Auto-resuming from this exact point in " .. tostring(remaining) .. "s...\n\n"
                .. "You can wait for auto-resume, add a new API key, or tap LISTEN SO FAR to preview what is ready."
            pcall(function() pViews.pauseBody.setText(txt) end)
        end

        updateMsg()

        quotaCountdownHandler = Handler(Looper.getMainLooper())
        local function tickCountdown()
            if not quotaPauseDialog then return end
            remaining = remaining - 1
            if remaining <= 0 then
                cancelQuotaCountdown()
                quotaExhaustedKeys = {}
                currentApiKeyIndex = 1
                showToast("Resuming generation from part " .. tostring(doneCount + 1) .. "...")
                if onResumeCallback then onResumeCallback() end
                return
            end
            updateMsg()
            quotaCountdownRunnable = Runnable({ run = tickCountdown })
            quotaCountdownHandler.postDelayed(quotaCountdownRunnable, 1000)
        end
        quotaCountdownRunnable = Runnable({ run = tickCountdown })
        quotaCountdownHandler.postDelayed(quotaCountdownRunnable, 1000)

        pViews.addApiResumeBtn.onClick = function()
            vibrate(30)
            if quotaCountdownHandler and quotaCountdownRunnable then
                pcall(function() quotaCountdownHandler.removeCallbacks(quotaCountdownRunnable) end)
            end
            showQuickApiUpdateDialog(function()
                cancelQuotaCountdown()
                if onResumeCallback then onResumeCallback() end
            end)
        end

        pViews.resumeNowBtn.onClick = function()
            vibrate(30)
            cancelQuotaCountdown()
            silentAutoRetryMode = true
            quotaExhaustedKeys = {}
            deadApiKeys = {}
            currentApiKeyIndex = 1
            showToast("Resuming silently...")
            if onResumeCallback then onResumeCallback() end
        end

        pViews.savePartialBtn.onClick = function()
            vibrate(30)
            cancelQuotaCountdown()
            if onSavePartialCallback then onSavePartialCallback() end
        end

        pDlg.show()
    end)
end

local function detectAutoEmotionPrefix(text)
    local lower = (text or ""):lower()
    if lower:find("ہنس") or lower:find("قہقہ") or lower:find("ہاہا") or lower:find("مسکرا")
       or lower:find("مذاق") or lower:find("لطیفہ") or lower:find("خوش") or lower:find("شکر ہے")
       or lower:find("laugh") or lower:find("haha") or lower:find("smile") or lower:find("funny") then
        return "Speak warmly with genuine happiness and light laughter: "
    end
    if lower:find("رویا") or lower:find("روئی") or lower:find("رونے") or lower:find("آنسو") or lower:find("اداس")
       or lower:find("غم") or lower:find("دکھ") or lower:find("تکلیف") or lower:find("سسکی") or lower:find("جدائی")
       or lower:find("موت") or lower:find("فوت") or lower:find("آہ") or lower:find("cry") or lower:find("tear")
       or lower:find("sad") or lower:find("sob") or lower:find("grief") then
        return "Speak in a deeply emotional, sad, heartbroken tone: "
    end
    if lower:find("غصہ") or lower:find("غصے") or lower:find("چلا کر") or lower:find("چلایا") or lower:find("نفرت")
       or lower:find("خبردار") or lower:find("گولی چلا دوں گا") or lower:find("مار دوں گا") or lower:find("تھپڑ") or lower:find("تھپر")
       or lower:find("چپیڑ") or lower:find("چپیر") or lower:find("آگ بگولا") or lower:find("خون کھول")
       or lower:find("angry") or lower:find("shout") or lower:find("furious") then
        return "Speak in a fierce, angry, commanding tone: "
    end
    if lower:find("ڈر") or lower:find("خوف") or lower:find("کانپ") or lower:find("وحشت") or lower:find("خطرہ") or lower:find("گھبرا")
       or lower:find("سایہ") or lower:find("بھوت") or lower:find("چڑیل") or lower:find("بھیانک")
       or lower:find("fear") or lower:find("scared") or lower:find("afraid") then
        return "Speak in a tense, suspenseful, hushed tone: "
    end
    if lower:find("حیران") or lower:find("حیرت") or lower:find("اچانک") or lower:find("دھماک")
       or lower:find("surprised") or lower:find("shocked") then
        return "Speak with urgent surprise and dramatic energy: "
    end
    if lower:find("سرگوشی") or lower:find("آہستہ سے کہا") or lower:find("whisper") then
        return "Whisper softly and cautiously: "
    end
    if lower:find("محبت") or lower:find("پیار") or lower:find("عشق") or lower:find("حوصلہ رکھو") or lower:find("love") or lower:find("romantic") then
        return "Speak warmly, gently, and affectionately: "
    end
    return "Speak like an expressive, engaging Urdu audiobook narrator: "
end

-- Smart Auto-Emotion Tagger (clean single-word tags — natural laughter, joy, anger, fear, sadness, zero repetition!):
local function detectInlineEmotionTag(sent)
    local lower = (sent or ""):lower()
    if lower:find("ہنس") or lower:find("قہقہ") or lower:find("ہاہا") or lower:find("laugh") or lower:find("haha") or lower:find("chuckle") then
        return "[laughing]"
    end
    if lower:find("مسکرا") or lower:find("شکر ہے") or lower:find("خوش") or lower:find("مبارک") or lower:find("فخر") or lower:find("smile") or lower:find("happy") or lower:find("joy") then
        return "[cheerful]"
    end
    if lower:find("غصہ") or lower:find("غصے") or lower:find("چلا کر") or lower:find("چلایا")
       or lower:find("خبردار") or lower:find("گولی چلا دوں گا") or lower:find("مار دوں گا")
       or lower:find("تھپڑ") or lower:find("چپیڑ") or lower:find("angry") or lower:find("furious") then
        return "[angry]"
    end
    if lower:find("رویا") or lower:find("روئی") or lower:find("رونے") or lower:find("آنسو")
       or lower:find("سسکی") or lower:find("اداس") or lower:find("غم") or lower:find("تکلیف")
       or lower:find("زخمی") or lower:find("درد") or lower:find("sad") or lower:find("cry") then
        return "[sad]"
    end
    if lower:find("ڈر") or lower:find("خوف") or lower:find("کانپ") or lower:find("وحشت")
       or lower:find("گھبرا") or lower:find("سایہ") or lower:find("بھوت") or lower:find("چیخ")
       or lower:find("fear") or lower:find("scared") then
        return "[fearful]"
    end
    if lower:find("اچانک") or lower:find("حیران") or lower:find("دھماک") or lower:find("گولی چلی")
       or lower:find("بجلی کڑک") or lower:find("ٹوٹ") or lower:find("بریک") or lower:find("surprised") then
        return "[surprised]"
    end
    if lower:find("سرگوشی") or lower:find("آہستہ سے کہا") or lower:find("whisper") then
        return "[whispering]"
    end
    return "[calm]"
end

local function formatSentenceWithInlineEmotion(sent, emotionChoice)
    local clean = (sent or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean == "" then return "" end
    if emotionChoice and emotionChoice ~= "Auto (Smart Emotion)" then
        return clean
    end
    local tag = detectInlineEmotionTag(clean)
    local qStart = clean:find('"', 1, true) or clean:find("“", 1, true) or clean:find("”", 1, true)
    if qStart and qStart > 6 and tag ~= "[calm]" then
        local narrPart = clean:sub(1, qStart - 1):gsub("%s+$", "")
        local quotePart = clean:sub(qStart)
        return "[calm] " .. narrPart .. " " .. tag .. " " .. quotePart
    end
    return tag .. " " .. clean
end

local function buildChunkExpressivePrompt(clausesList, emotionChoice, useSimpleFallback, voiceName)
    local rawParts = {}
    for _, c in ipairs(clausesList) do
        local t = (type(c) == "table") and c.text or tostring(c)
        if t and #t > 0 then table.insert(rawParts, t) end
    end
    local plainJoined = table.concat(rawParts, " ")
    local vGender = getVoiceGenderLabel(voiceName or selectedVoice or "Puck")
    if useSimpleFallback then
        return "Read every word of the following text aloud verbatim in ONE consistent, clear " .. vGender .. " studio narrator voice without skipping anything: " .. plainJoined
    end
    local emName = emotionChoice or selectedEmotion
    if emName ~= "Auto (Smart Emotion)" then
        local pref = EMOTION_PREFIXES[emName] or "Speak in a natural, clear tone: "
        return "Using ONE consistent, clear " .. vGender .. " studio narrator voice, " .. pref .. plainJoined
    end
    local taggedParts = {}
    for _, c in ipairs(clausesList) do
        local t = (type(c) == "table") and c.text or tostring(c)
        if t and #t > 0 then
            table.insert(taggedParts, formatSentenceWithInlineEmotion(t, emName))
        end
    end
    return "Read every sentence of this story aloud verbatim in ONE consistent, crystal-clear " .. vGender .. " studio narrator voice (never changing speaker gender or audio quality). Express each bracketed emotion naturally (including warm laughter for [laughing], joy for [cheerful], anger for [angry], fear for [fearful], sadness for [sad]) without speaking the bracketed words aloud and without skipping any word: " .. table.concat(taggedParts, " ")
end

local function buildExpressiveTTSPrompt(rawText, emotionName, useSimpleFallback)
    local clean = (rawText or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if useSimpleFallback then
        return "Read aloud verbatim in a natural voice: " .. clean
    end
    local emName = emotionName or selectedEmotion
    local prefix = ""
    if emName == "Auto (Smart Emotion)" then
        prefix = detectAutoEmotionPrefix(clean)
    else
        prefix = EMOTION_PREFIXES[emName] or "Speak in a natural, clear tone: "
    end
    return prefix .. clean
end

-- ===== AUDIO FETCH (USED BY SINGLE AUDIO, PODCAST & SFX MODE) =====
local function fetchAudioSimple(line, voice, apikey, model, callback, emotionOverride, useFallbackPrompt, prebuiltPromptText)
    local activeModel = DEFAULT_TTS_MODEL
    local activeVoice = isValidVoice(voice) and voice or "Puck"
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. activeModel .. ":generateContent?key=" .. cleanApiKey(apikey)

    local promptText = prebuiltPromptText
    if not promptText or useFallbackPrompt then
        promptText = buildExpressiveTTSPrompt(line, emotionOverride or selectedEmotion, useFallbackPrompt)
    end
    local requestBody = {
        contents = { { parts = { { text = promptText } } } },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = { voiceConfig = { prebuiltVoiceConfig = { voiceName = activeVoice } } }
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({
        run = function()
            if not completed then
                completed = true
                if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
                callback(false, nil, "Timeout (75s)", 408)
            end
        end
    })
    timeoutHandler.postDelayed(timeoutRunnable, 75000)

    local req = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts then
                    for _, part in ipairs(candidate.content.parts) do
                        if part.inlineData and part.inlineData.data then
                            local okDec, audioBytes = pcall(function()
                                return Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                            end)
                            if okDec and audioBytes then
                                consecutiveQuotaPauses = 0
                                callback(true, audioBytes, nil, 200)
                                return
                            end
                        end
                    end
                end
            end
            if not useFallbackPrompt then
                fetchAudioSimple(line, voice, apikey, model, callback, emotionOverride, true, nil)
                return
            end
            callback(false, nil, "No audio in response", 200)
        elseif code == 400 and not useFallbackPrompt and content and not tostring(content):find("API_KEY_INVALID") then
            fetchAudioSimple(line, voice, apikey, model, callback, emotionOverride, true, nil)
        else
            callback(false, nil, extractApiError(code, content), code)
        end
    end)
    currentHttpRequest = req
end

-- ===== MULTI-SPEAKER PODCAST TTS FETCH (HOST + GUEST IN ONE NATURAL STUDIO CALL) =====
local function fetchMultiSpeakerPodcastAudio(turnsList, hostVoice, guestVoice, apikey, callback)
    local activeModel = DEFAULT_TTS_MODEL
    local hVoice = isValidVoice(hostVoice) and hostVoice or "Puck"
    local gVoice = isValidVoice(guestVoice) and guestVoice or "Kore"
    if hVoice == gVoice then
        gVoice = (hVoice == "Kore") and "Puck" or "Kore"
    end

    local scriptLines = {}
    for _, t in ipairs(turnsList) do
        local sp = ((t.speaker or ""):lower() == "guest") and "Guest" or "Host"
        local tx = tostring(t.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #tx > 0 then
            table.insert(scriptLines, sp .. ": " .. tx)
        end
    end
    local fullPrompt = "Perform this warm, engaging studio podcast conversation between Host and Guest with natural chemistry, realistic reactions, and smooth conversational rhythm. Read every single line verbatim in the exact same language without skipping or repeating any words:\n" .. table.concat(scriptLines, "\n")

    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. activeModel .. ":generateContent?key=" .. cleanApiKey(apikey)
    local requestBody = {
        contents = { { parts = { { text = fullPrompt } } } },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = {
                multiSpeakerVoiceConfig = {
                    speakerVoiceConfigs = {
                        {
                            speaker = "Host",
                            voiceConfig = { prebuiltVoiceConfig = { voiceName = hVoice } }
                        },
                        {
                            speaker = "Guest",
                            voiceConfig = { prebuiltVoiceConfig = { voiceName = gVoice } }
                        }
                    }
                }
            }
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({
        run = function()
            if not completed then
                completed = true
                if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
                callback(false, nil, "Timeout (75s)", 408)
            end
        end
    })
    timeoutHandler.postDelayed(timeoutRunnable, 75000)

    currentHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts then
                    for _, part in ipairs(candidate.content.parts) do
                        if part.inlineData and part.inlineData.data then
                            local okDec, audioBytes = pcall(function()
                                return Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                            end)
                            if okDec and audioBytes then
                                consecutiveQuotaPauses = 0
                                callback(true, audioBytes, nil, 200)
                                return
                            end
                        end
                    end
                end
            end
            callback(false, nil, "No audio in multi-speaker response", 200)
        else
            callback(false, nil, extractApiError(code, content), code)
        end
    end)
end

-- ===== UTF-8 SAFE SENTENCE & STUDIO CHUNK SPLITTING =====
function splitIntoSentences(text)
    local rawLines = {}
    local norm1 = (text or "")
        :gsub("\r\n", "\n")
        :gsub("۔", "۔\n")
        :gsub("؟", "؟\n")
        :gsub("！", "!\n")
        :gsub("([%.%!%?]+)%s+", "%1\n")
        :gsub("%s+%-%s+", "\n")
        :gsub("%s+—%s+", "\n")

    for line in norm1:gmatch("[^\n]+") do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if #s > 0 then
            if #s <= 340 then
                table.insert(rawLines, s)
            else
                local subNorm = s:gsub("،", "،\n"):gsub("؛", "؛\n"):gsub("([%,%;]+)%s+", "%1\n")
                local cur = ""
                for part in subNorm:gmatch("[^\n]+") do
                    local p = part:gsub("^%s+", ""):gsub("%s+$", "")
                    if #p > 0 then
                        if #cur + #p + 1 > 260 and #cur > 0 then
                            table.insert(rawLines, cur)
                            cur = p
                        else
                            cur = (#cur > 0) and (cur .. " " .. p) or p
                        end
                    end
                end
                if #cur > 0 then table.insert(rawLines, cur) end
            end
        end
    end

    local sentences = {}
    local carry = ""
    for _, s in ipairs(rawLines) do
        if carry ~= "" then
            s = carry .. " " .. s
            carry = ""
        end
        if #s < 38 then
            carry = s
        else
            table.insert(sentences, s)
        end
    end
    if carry ~= "" then
        if #sentences > 0 then
            sentences[#sentences] = sentences[#sentences] .. " " .. carry
        else
            table.insert(sentences, carry)
        end
    end

    if #sentences == 0 and text and #text > 0 then
        table.insert(sentences, text)
    end
    return sentences
end

function splitTextIntoChunks(text, maxChunkSize)
    local targetMax = maxChunkSize or 1350
    if #text <= targetMax then
        return { text }
    end
    local sentences = splitIntoSentences(text)
    local chunks = {}
    local currentChunk = ""
    local currentSentCount = 0

    for _, sent in ipairs(sentences) do
        if (#currentChunk + #sent + 2 > targetMax or currentSentCount >= 7) and #currentChunk > 0 then
            table.insert(chunks, currentChunk)
            currentChunk = sent
            currentSentCount = 1
        else
            if currentChunk == "" then
                currentChunk = sent
                currentSentCount = 1
            else
                currentChunk = currentChunk .. " " .. sent
                currentSentCount = currentSentCount + 1
            end
        end
    end
    if currentChunk ~= "" then table.insert(chunks, currentChunk) end
    if #chunks == 0 then table.insert(chunks, text) end
    return chunks
end

-- ===== MODE 4: REAL STUDIO SOUND EFFECTS ENGINE V14 (45 SURFACE-AWARE STUDIO SOUNDS + ZERO-SKIP ENGINE) =====
local sfxCacheDir = context.getCacheDir().getPath() .. "/sfx_wav_v18"
local publicSfxDir = "/storage/emulated/0/Download/AudioCraft_SFX_v18"
pcall(function()
    local d1 = File(sfxCacheDir)
    if not d1.exists() then d1.mkdirs() end
    local d2 = File(publicSfxDir)
    if not d2.exists() then d2.mkdirs() end
end)

-- 45 Verified Official Google Actions Sound Library Studio .ogg URLs + Embedded Real Recordings
local REQUIRED_SFX_LIST = {
    -- Doors & Bells
    { key = "door_open", ogg = "https://actions.google.com/sounds/v1/doors/creaking_wooden_door.ogg", query = "wooden door open creak", ambient = false, skipSec = 0.0 },
    { key = "door_close", ogg = "https://actions.google.com/sounds/v1/doors/door_close.ogg", query = "wooden door close shut", ambient = false, skipSec = 0.0 },
    { key = "iron_door_open", ogg = "https://actions.google.com/sounds/v1/doors/deadbolt_lock.ogg", query = "iron gate metal door open", ambient = false, skipSec = 0.0 },
    { key = "iron_door_close", ogg = "https://actions.google.com/sounds/v1/doors/heavy_door_close.ogg", query = "heavy iron door slam close", ambient = false, skipSec = 0.0 },
    { key = "knock", ogg = "https://actions.google.com/sounds/v1/doors/knock_on_wooden_door.ogg", query = "knock on wooden door", ambient = false, skipSec = 0.0 },
    { key = "doorbell", ogg = "", query = "house doorbell ding dong", ambient = false, skipSec = 0.0 },
    { key = "phone_ring", ogg = "https://actions.google.com/sounds/v1/household/phone_ringing.ogg", query = "telephone ring", ambient = false, skipSec = 0.0 },
    -- Weather & Nature
    { key = "rain", ogg = "https://actions.google.com/sounds/v1/weather/rain_heavy_loud.ogg", query = "soft rain falling", ambient = true, skipSec = 1.0 },
    { key = "rain_light", ogg = "https://actions.google.com/sounds/v1/weather/light_rain.ogg", query = "light soft rain", ambient = true, skipSec = 0.4 },
    { key = "rain_roof", ogg = "https://actions.google.com/sounds/v1/weather/rain_on_roof.ogg", query = "rain falling on roof", ambient = true, skipSec = 0.4 },
    { key = "rain_drip", ogg = "https://actions.google.com/sounds/v1/weather/rain_water_dripping_softly.ogg", query = "water drops dripping softly", ambient = true, skipSec = 0.2 },
    { key = "rain_indoor", ogg = "https://actions.google.com/sounds/v1/weather/rain_heavy_quiet_interior.ogg", query = "rain heard from indoors", ambient = true, skipSec = 0.4 },
    { key = "wind_breeze", ogg = "https://actions.google.com/sounds/v1/weather/light_breeze.ogg", query = "cool gentle breeze", ambient = true, skipSec = 0.3 },
    { key = "leaves_rustle", ogg = "https://actions.google.com/sounds/v1/weather/leaves_russle_on_tree.ogg", query = "leaves rustling on tree", ambient = true, skipSec = 0.2 },
    { key = "tea_sip", ogg = "https://actions.google.com/sounds/v1/foley/sipping_hot_liquid.ogg", query = "sipping hot tea", ambient = false, skipSec = 0.0 },
    { key = "cup_clink", ogg = "", query = "tea cup saucer clink", ambient = false, skipSec = 0.0 },
    { key = "phone_dial", ogg = "", query = "telephone dialing buttons", ambient = false, skipSec = 0.0 },
    { key = "stream_water", ogg = "https://actions.google.com/sounds/v1/water/small_stream_flowing.ogg", query = "small stream water flowing", ambient = true, skipSec = 0.2 },
    { key = "sea_waves", ogg = "https://actions.google.com/sounds/v1/water/waves_crashing_on_rock_beach.ogg", query = "ocean waves beach", ambient = true, skipSec = 0.2 },
    { key = "thunder", ogg = "https://actions.google.com/sounds/v1/weather/thunder_crack.ogg", query = "thunder crack", ambient = false, skipSec = 0.0 },
    { key = "wind", ogg = "https://actions.google.com/sounds/v1/weather/forest_wind_summer.ogg", query = "soft wind breeze", ambient = true, skipSec = 0.5 },
    { key = "birds", ogg = "https://actions.google.com/sounds/v1/animals/june_songbirds.ogg", query = "morning songbirds chirping", ambient = true, skipSec = 0.0 },
    { key = "fire", ogg = "https://actions.google.com/sounds/v1/ambiences/fire.ogg", query = "fire flames crackling", ambient = true, skipSec = 0.2 },
    { key = "water_splash", ogg = "https://actions.google.com/sounds/v1/foley/water_splashing.ogg", query = "water splash", ambient = false, skipSec = 0.0 },
    { key = "dog_bark", ogg = "https://actions.google.com/sounds/v1/ambiences/outdoor_ambience_dog_barking.ogg", query = "dog barking night", ambient = false, skipSec = 0.0 },
    -- Surface-Specific Footsteps (Wood, Gravel/Trail, Concrete Stairs, Mud, Forest, Running, General)
    { key = "footsteps", ogg = "https://actions.google.com/sounds/v1/foley/walking_on_concrete_series.ogg", query = "footsteps walking", ambient = true, skipSec = 0.0 },
    { key = "footsteps_wood", ogg = "https://actions.google.com/sounds/v1/foley/walking_on_wood_floor.ogg", query = "footsteps on wooden floor", ambient = true, skipSec = 0.0 },
    { key = "footsteps_gravel", ogg = "https://actions.google.com/sounds/v1/foley/walking_on_gravel_path.ogg", query = "footsteps on gravel mountain trail", ambient = true, skipSec = 0.0 },
    { key = "footsteps_stairs", ogg = "https://actions.google.com/sounds/v1/foley/walk_down_concrete_stairs.ogg", query = "footsteps on stone stairs", ambient = true, skipSec = 0.0 },
    { key = "footsteps_mud", ogg = "https://actions.google.com/sounds/v1/foley/walking_in_a_mud_puddle.ogg", query = "footsteps in mud puddle", ambient = true, skipSec = 0.0 },
    { key = "footsteps_forest", ogg = "https://actions.google.com/sounds/v1/foley/walking_in_forest.ogg", query = "footsteps in forest leaves", ambient = true, skipSec = 0.0 },
    { key = "footsteps_run", ogg = "https://actions.google.com/sounds/v1/foley/running_on_concrete.ogg", query = "running footsteps", ambient = true, skipSec = 0.0 },
    { key = "footsteps_group", ogg = "", query = "multiple people walking footsteps", ambient = true, skipSec = 0.0 },
    { key = "footsteps_heels", ogg = "", query = "high heels walking on floor", ambient = true, skipSec = 0.0 },
    { key = "footsteps_soft", ogg = "", query = "soft quiet footsteps slippers", ambient = true, skipSec = 0.0 },
    -- Combat, Weapons & Props
    { key = "slap", ogg = "https://actions.google.com/sounds/v1/cartoon/slapping_bare_skin.ogg", query = "slap face hit", ambient = false, skipSec = 0.0 },
    { key = "punch", ogg = "https://actions.google.com/sounds/v1/foley/hit_and_rattle.ogg", query = "punch body hit", ambient = false, skipSec = 0.0 },
    { key = "gunshot", ogg = "https://actions.google.com/sounds/v1/weapons/gunshot_and_echo_long.ogg", query = "pistol gunshot sound", ambient = false, skipSec = 0.0 },
    { key = "pistol_cock", ogg = "https://actions.google.com/sounds/v1/weapons/handgun_cocking.ogg", query = "pistol cocking sound", ambient = false, skipSec = 0.0 },
    { key = "explosion", ogg = "https://actions.google.com/sounds/v1/weapons/explosion_hiss_bop_bang.ogg", query = "explosion boom", ambient = false, skipSec = 0.0 },
    { key = "glass_break", ogg = "https://actions.google.com/sounds/v1/doors/glass_shower_door_shake.ogg", query = "glass break shatter", ambient = false, skipSec = 0.0 },
    { key = "chains", ogg = "https://actions.google.com/sounds/v1/foley/chain_on_metal_post.ogg", query = "metal chains rattling", ambient = false, skipSec = 0.0 },
    -- Vehicles & Emergency (Real Studio Recordings)
    { key = "car_start", ogg = "https://actions.google.com/sounds/v1/transportation/engine_start_up.ogg", query = "car engine start up", ambient = false, skipSec = 0.0 },
    { key = "car_drive", ogg = "https://actions.google.com/sounds/v1/transportation/driving_in_car_interior.ogg", query = "car driving interior", ambient = true, skipSec = 0.2 },
    { key = "car_stop", ogg = "https://actions.google.com/sounds/v1/transportation/car_stop_and_go.ogg", query = "car stopping engine off", ambient = false, skipSec = 0.0 },
    { key = "car_brakes", ogg = "https://actions.google.com/sounds/v1/transportation/muscle_car_highway_skid.ogg", query = "car brakes tire skid", ambient = false, skipSec = 0.0 },
    { key = "car_horn", ogg = "https://actions.google.com/sounds/v1/transportation/car_horn.ogg", query = "car horn honk", ambient = false, skipSec = 0.0 },
    { key = "car_door", ogg = "https://actions.google.com/sounds/v1/transportation/car_door_closing.ogg", query = "car door closing", ambient = false, skipSec = 0.0 },
    { key = "car_crash", ogg = "https://actions.google.com/sounds/v1/sports/skateboard_trick_and_crash.ogg", query = "car crash smash", ambient = false, skipSec = 0.0 },
    { key = "ambulance", ogg = "https://actions.google.com/sounds/v1/emergency/ambulance_siren.ogg", query = "ambulance siren wail", ambient = true, skipSec = 0.3 },
    { key = "police_siren", ogg = "https://actions.google.com/sounds/v1/emergency/emergency_siren_approaching.ogg", query = "police siren approaching", ambient = true, skipSec = 0.2 },
    -- Human Emotions & Heartbeat
    { key = "scream_male", ogg = "https://actions.google.com/sounds/v1/horror/agony_scream.ogg", query = "man scream sound effect", ambient = false, skipSec = 0.0 },
    { key = "scream_female", ogg = "https://actions.google.com/sounds/v1/horror/female_monster_attacking.ogg", query = "woman scream sound effect", ambient = false, skipSec = 0.0 },
    { key = "scream_horror", ogg = "https://actions.google.com/sounds/v1/horror/female_monster_attacking.ogg", query = "scary horror monster scream", ambient = false, skipSec = 0.0 },
    { key = "crying_male", ogg = "https://actions.google.com/sounds/v1/human_voices/male_crying.ogg", query = "man crying sobbing", ambient = true, skipSec = 0.0 },
    { key = "crying_female", ogg = "https://actions.google.com/sounds/v1/human_voices/male_dramatic_crying.ogg", query = "woman crying sobbing", ambient = true, skipSec = 0.0 },
    { key = "heartbeat", ogg = "", query = "human heartbeat lub dub", ambient = true, skipSec = 0.0 },
    -- Night Ambiences
    { key = "forest_night", ogg = "https://actions.google.com/sounds/v1/animals/afternoon_crickets_long.ogg", query = "night forest crickets", ambient = true, skipSec = 0.2 },
    { key = "night_insects", ogg = "https://actions.google.com/sounds/v1/animals/cicada_chirp.ogg", query = "night crickets sound", ambient = true, skipSec = 0.2 },
    { key = "village_night", ogg = "https://actions.google.com/sounds/v1/ambiences/crickets_with_distant_traffic.ogg", query = "quiet night crickets", ambient = true, skipSec = 0.2 }
}

local FOOTSTEP_SFX_SET = {
    footsteps = true, footsteps_wood = true, footsteps_gravel = true,
    footsteps_stairs = true, footsteps_mud = true, footsteps_forest = true, footsteps_run = true
}

local AMBIENT_SFX_SET = {
    rain = true, rain_light = true, rain_roof = true, rain_drip = true, rain_indoor = true, wind_breeze = true, leaves_rustle = true, stream_water = true, sea_waves = true, birds = true, forest_night = true,
    night_insects = true, village_night = true, ambulance = true, police_siren = true,
    wind = true, fire = true, heartbeat = true,
    footsteps = true, footsteps_wood = true, footsteps_gravel = true,
    footsteps_stairs = true, footsteps_mud = true, footsteps_forest = true, footsteps_run = true, footsteps_group = true, footsteps_heels = true, footsteps_soft = true,
    car_drive = true, crying_male = true, crying_female = true
}

local WARM_FILTER_SFX_SET = {
    rain = true, rain_light = true, rain_indoor = true, wind = true, wind_breeze = true
}

local SINGLE_IMPACT_SFX_SET = {
    slap = true, punch = true, door_close = true, iron_door_close = true,
    gunshot = true, pistol_cock = true, explosion = true, glass_break = true,
    thunder = true, phone_ring = true, doorbell = true, car_horn = true,
    car_brakes = true, car_door = true, car_crash = true, chains = true,
    water_splash = true, dog_bark = true, tea_sip = true,
    scream_male = true, scream_female = true, scream_horror = true
}

local BLOCKED_VOCAL_SFX = {
    laugh = true, laughing = true, laughter = true, haha = true, giggle = true, chuckle = true,
    talk = true, talking = true, voice = true, speech = true, whisper = true, whispering = true,
    cough = true, sneeze = true
}

local DIRECT_OGG_MAP = {}
local QUERY_MAP = {}
local SKIP_SEC_MAP = {}
for _, it in ipairs(REQUIRED_SFX_LIST) do
    if it.ogg and it.ogg ~= "" then DIRECT_OGG_MAP[it.key] = it.ogg end
    QUERY_MAP[it.key] = it.query
    SKIP_SEC_MAP[it.key] = it.skipSec or 0.0
end

local function copyFileBinary(srcPath, dstPath)
    local ok = pcall(function()
        local src = File(srcPath)
        if not src.exists() or src.length() <= 44 then return end
        local fis = FileInputStream(src)
        local fos = FileOutputStream(File(dstPath))
        local buf = byte[8192]
        while true do
            local l = fis.read(buf)
            if l == -1 then break end
            fos.write(buf, 0, l)
        end
        fis.close()
        fos.close()
    end)
    return ok
end

-- Smooth, Natural Offline Studio Synthesizer (defined BEFORE embedded WAV writers so it is always in scope!)
local function synthesizeSfxToWav(sfxKey, outWavPath)
    local sr = 24000
    local sfx = (sfxKey or ""):lower()
    local dur = 1.6
    if sfx == "slap" or sfx == "punch" or sfx == "pistol_cock" then dur = 0.85
    elseif sfx == "door_close" or sfx == "iron_door_close" or sfx == "car_door" then dur = 1.15
    elseif sfx == "door_open" or sfx == "iron_door_open" then dur = 1.55
    elseif sfx == "doorbell" then dur = 1.85
    elseif sfx == "knock" or sfx == "chains" then dur = 1.45
    elseif sfx == "thunder" or sfx == "gunshot" or sfx == "explosion" or sfx == "car_crash" then dur = 2.1
    elseif sfx == "phone_ring" or sfx == "car_start" or sfx == "car_stop" or sfx == "car_brakes" then dur = 1.9
    elseif sfx == "scream_male" or sfx == "scream_female" or sfx == "scream_horror" then dur = 1.7
    elseif AMBIENT_SFX_SET[sfx] then dur = 3.0
    else dur = 1.6 end

    local numSamples = math.floor(sr * dur)
    local chunks = {}
    local pi2 = 2 * math.pi
    math.randomseed(13579)
    local lp1, lp2 = 0, 0

    for i = 0, numSamples - 1 do
        local t = i / sr
        local r = math.random() * 2 - 1
        lp1 = lp1 * 0.85 + r * 0.15
        lp2 = lp2 * 0.94 + lp1 * 0.06
        local hp = r - lp1
        local val = 0

        if sfx == "slap" then
            local snap = (t < 0.04) and (hp * math.exp(-t * 65) * 1.1 + math.sin(pi2 * (1050 * math.exp(-t * 35) + 260) * t) * math.exp(-t * 45) * 0.9) or 0
            local reverb = (t >= 0.02) and (lp1 * math.exp(-(t - 0.02) * 16) * 0.4) or 0
            val = (snap + reverb) * 28000
        elseif sfx == "punch" then
            local body = math.sin(pi2 * (155 * math.exp(-t * 20) + 50) * t) * math.exp(-t * 14)
            local impact = lp1 * math.exp(-t * 28) * 0.8
            val = (body + impact) * 28000
        elseif sfx == "door_open" then
            local latch = (t < 0.06) and ((math.sin(pi2 * 1100 * t) * 0.4 + lp1 * 0.6) * math.exp(-t * 60)) or 0
            local creak = 0
            if t >= 0.12 and t < 1.40 then
                local dt = t - 0.12
                local f0 = 210 + 55 * math.sin(pi2 * 1.5 * dt)
                local harm = math.sin(pi2 * f0 * dt) + 0.55 * math.sin(pi2 * f0 * 2 * dt) + 0.25 * math.sin(pi2 * f0 * 3 * dt)
                local env = math.sin(math.pi * (dt / 1.28))
                creak = (harm * 0.55 + lp2 * 0.25) * env
            end
            val = (latch + creak) * 26000
        elseif sfx == "door_close" or sfx == "car_door" then
            local snap = (t < 0.04) and (lp1 * math.exp(-t * 65) * 0.7) or 0
            local dt = math.max(0, t - 0.03)
            local slam = (t >= 0.03) and ((math.sin(pi2 * (115 * math.exp(-dt * 20) + 52) * dt) * 0.8 + lp2 * 0.6) * math.exp(-dt * 8)) or 0
            val = (snap + slam) * 28000
        elseif sfx == "iron_door_open" then
            local clank = (t < 0.12) and ((math.sin(pi2 * 680 * t) * 0.5 + math.sin(pi2 * 1540 * t) * 0.4 + hp * 0.5) * math.exp(-t * 28)) or 0
            local screech = 0
            if t >= 0.15 and t < 1.45 then
                local dt = t - 0.15
                local f1 = 520 + 95 * math.sin(pi2 * 2.1 * dt)
                local f2 = 1180 + 140 * math.cos(pi2 * 1.7 * dt)
                local env = math.sin(math.pi * (dt / 1.30))
                screech = (math.sin(pi2 * f1 * dt) * 0.45 + math.sin(pi2 * f2 * dt) * 0.35 + hp * 0.15) * env
            end
            val = (clank + screech) * 26000
        elseif sfx == "iron_door_close" then
            local clang = (math.sin(pi2 * 145 * t) * 0.55 + math.sin(pi2 * 430 * t) * 0.35 + math.sin(pi2 * 980 * t) * 0.25 + math.sin(pi2 * 1720 * t) * 0.15) * math.exp(-t * 6.5)
            local burst = (t < 0.08) and (hp * math.exp(-t * 40) * 0.8) or 0
            val = (clang + burst) * 29000
        elseif sfx == "knock" then
            local kTimes = {0.02, 0.30, 0.58, 0.88}
            for _, kt in ipairs(kTimes) do
                if t >= kt and t < kt + 0.20 then
                    local dt = t - kt
                    local wood = math.sin(pi2 * (260 * math.exp(-dt * 35) + 140) * dt) * math.exp(-dt * 24) * 0.75
                    local box = math.sin(pi2 * 380 * dt) * math.exp(-dt * 38) * 0.45
                    local attack = lp1 * math.exp(-dt * 55) * 0.6
                    val = val + (wood + box + attack) * 27000
                end
            end
        elseif sfx == "doorbell" then
            -- Warm, soft residential chime Doorbell ("Ding - Dong": G5 784Hz -> E5 659.25Hz, smooth mellow bell decay)
            local ding = 0
            if t >= 0.04 and t < 1.10 then
                local dt = t - 0.04
                local env = math.min(1.0, dt / 0.014) * math.exp(-dt * 4.2)
                ding = (math.sin(pi2 * 783.99 * dt) * 0.78 + math.sin(pi2 * 1567.98 * dt) * 0.16 * math.exp(-dt * 6.0) + math.sin(pi2 * 2351.97 * dt) * 0.06 * math.exp(-dt * 10.0)) * env
            end
            local dong = 0
            if t >= 0.46 then
                local dt = t - 0.46
                local env = math.min(1.0, dt / 0.014) * math.exp(-dt * 2.9)
                dong = (math.sin(pi2 * 659.25 * dt) * 0.80 + math.sin(pi2 * 1318.50 * dt) * 0.15 * math.exp(-dt * 5.5) + math.sin(pi2 * 1977.75 * dt) * 0.05 * math.exp(-dt * 9.0)) * env
            end
            val = (ding + dong) * 19500
        elseif sfx == "cup_clink" then
            -- Delicate porcelain teacup & saucer clink
            local c1, c2 = 0, 0
            if t >= 0.06 and t < 0.35 then
                local dt = t - 0.06
                local env = math.min(1.0, dt / 0.002) * math.exp(-dt * 36)
                c1 = (math.sin(pi2 * 2740 * dt) * 0.55 + math.sin(pi2 * 4180 * dt) * 0.30 + math.sin(pi2 * 5620 * dt) * 0.15) * env
            end
            if t >= 0.48 and t < 0.78 then
                local dt = t - 0.48
                local env = math.min(1.0, dt / 0.002) * math.exp(-dt * 42)
                c2 = (math.sin(pi2 * 2960 * dt) * 0.50 + math.sin(pi2 * 4420 * dt) * 0.28) * env * 0.75
            end
            val = (c1 + c2) * 18500
        elseif sfx == "phone_dial" then
            -- Realistic telephone receiver lift click + crisp DTMF keypad dialing tones
            local click = (t < 0.04) and (lp1 * math.exp(-t * 70) * 0.8) or 0
            local tones = { {0.14, 697, 1209}, {0.34, 770, 1336}, {0.54, 852, 1477}, {0.74, 770, 1209}, {0.94, 697, 1477} }
            local dtmf = 0
            for _, tn in ipairs(tones) do
                if t >= tn[1] and t < tn[1] + 0.11 then
                    local dt = t - tn[1]
                    local env = math.min(1.0, dt / 0.006) * math.min(1.0, (0.11 - dt) / 0.008)
                    dtmf = dtmf + (math.sin(pi2 * tn[2] * dt) + math.sin(pi2 * tn[3] * dt)) * 0.35 * env
                end
            end
            val = (click + dtmf) * 18000
        elseif sfx == "footsteps_heels" then
            -- Crisp high-heel clicks ("ٹک... ٹک... ٹک") on polished floor
            local dt = t % 0.46
            if dt < 0.075 then
                local click = (math.sin(pi2 * 1850 * dt) * 0.45 + math.sin(pi2 * 3400 * dt) * 0.30 + hp * 0.65) * math.exp(-dt * 58)
                local tap = math.sin(pi2 * 420 * dt) * math.exp(-dt * 42) * 0.35
                val = (click + tap) * 23000
            end
        elseif sfx == "footsteps_group" then
            -- Layered multiple people walking together (3 staggered footsteps + subtle heel click)
            local s1 = (t % 0.48 < 0.11) and ((math.sin(pi2 * 145 * (t % 0.48)) * 0.55 + lp1 * 0.55) * math.exp(-(t % 0.48) * 32)) or 0
            local t2 = (t + 0.17) % 0.53
            local s2 = (t2 < 0.10) and ((math.sin(pi2 * 180 * t2) * 0.50 + lp1 * 0.45) * math.exp(-t2 * 35)) or 0
            local t3 = (t + 0.31) % 0.44
            local s3 = (t3 < 0.065) and ((math.sin(pi2 * 1750 * t3) * 0.35 + hp * 0.55) * math.exp(-t3 * 55)) or 0
            val = (s1 * 0.70 + s2 * 0.65 + s3 * 0.55) * 21500
        elseif sfx == "footsteps_soft" then
            -- Quiet stealthy / slipper footsteps on indoor floor
            local dt = t % 0.56
            if dt < 0.11 then
                val = (math.sin(pi2 * 115 * dt) * 0.35 + (lp1 - lp2) * 0.55) * math.exp(-dt * 30) * 15500
            end
        elseif FOOTSTEP_SFX_SET[sfx] then
            local period = (sfx == "footsteps_run") and 0.28 or 0.48
            local dt = t % period
            if dt < 0.14 then
                local baseF = (sfx == "footsteps_wood") and 195 or 125
                local grit = (sfx == "footsteps_gravel" or sfx == "footsteps_forest") and (hp * 0.65) or (lp1 * 0.65)
                val = (math.sin(pi2 * baseF * dt) * math.exp(-dt * 28) * 0.65 + grit * math.exp(-dt * 32)) * 22000
            end
        elseif sfx == "thunder" then
            local crack = (t < 0.15) and (r * math.exp(-t * 16) * 0.85) or 0
            local rollEnv = math.exp(-t * 1.4) * (0.65 + 0.35 * math.sin(pi2 * 3.0 * t))
            val = (crack + lp2 * 2.1 * rollEnv) * 28000
        elseif sfx == "rain" or sfx == "wind" or sfx == "fire" then
            local mod = 0.82 + 0.18 * math.sin(pi2 * 0.45 * t)
            val = (lp2 * 1.3 + lp1 * 0.35) * mod * 18000
        elseif sfx == "gunshot" then
            local bang = (t < 0.09) and (r * math.exp(-t * 32) * 1.0 + math.sin(pi2 * (280 * math.exp(-t * 25) + 75) * t) * math.exp(-t * 20) * 0.9) or 0
            local echo = (t >= 0.05) and (lp1 * math.exp(-(t - 0.05) * 3.2) * 0.65) or 0
            val = (bang + echo) * 30000
        elseif sfx == "pistol_cock" or sfx == "chains" then
            if t >= 0.04 and t < 0.18 then
                local dt = t - 0.04
                val = (math.sin(pi2 * 1450 * dt) * 0.5 + hp * 0.7) * math.exp(-dt * 35) * 26000
            elseif t >= 0.26 and t < 0.42 then
                local dt = t - 0.26
                val = (math.sin(pi2 * 1950 * dt) * 0.55 + hp * 0.75) * math.exp(-dt * 32) * 28000
            end
        elseif sfx == "explosion" or sfx == "car_crash" then
            val = (r * math.exp(-t * 8) * 0.9 + lp2 * 2.3 * math.exp(-t * 1.6)) * 29000
        elseif sfx == "car_start" then
            if t < 0.65 then
                local crank = 0.55 + 0.45 * math.sin(pi2 * 7.5 * t)
                val = (math.sin(pi2 * 105 * t) * 0.55 + math.sin(pi2 * 210 * t) * 0.3 + lp1 * 0.45) * crank * 25000
            else
                local dt = t - 0.65
                local revFreq = 75 + 95 * math.exp(-dt * 2.0)
                val = (math.sin(pi2 * revFreq * dt) * 0.6 + math.sin(pi2 * revFreq * 2 * dt) * 0.35 + lp2 * 0.4) * math.exp(-dt * 0.45) * 28000
            end
        elseif sfx == "car_drive" then
            local f0 = 82 + 22 * math.sin(pi2 * 0.45 * t)
            val = (math.sin(pi2 * f0 * t) * 0.5 + math.sin(pi2 * f0 * 2 * t) * 0.3 + lp2 * 0.5) * 24000
        elseif sfx == "car_stop" then
            local f0 = math.max(25, 110 - 58 * t)
            local env = math.max(0, 1.0 - (t / 1.80))
            val = (math.sin(pi2 * f0 * t) * 0.6 + math.sin(pi2 * f0 * 2 * t) * 0.25 + lp2 * 0.45) * env * 25000
        elseif sfx == "car_brakes" then
            if t < 1.35 then
                local env = math.sin(math.pi * (t / 1.35))
                -- Filtered tire grit + subtle rubber friction (no harsh sine whistle)
                val = (hp * 0.72 + lp1 * 0.45 + math.sin(pi2 * (1180 - 180 * t) * t) * 0.16) * env * 24000
            end
        elseif sfx == "car_horn" then
            val = (math.sin(pi2 * 415 * t) + math.sin(pi2 * 515 * t)) * 0.48 * 25000
        elseif sfx == "ambulance" or sfx == "police_siren" then
            local rate = (sfx == "police_siren") and 2.4 or 1.45
            local sirenFreq = 690 + 230 * math.sin(pi2 * rate * t)
            val = (math.sin(pi2 * sirenFreq * t) * 0.75 + math.sin(pi2 * sirenFreq * 2 * t) * 0.2) * 23000
        elseif sfx == "birds" then
            local noteIdx = math.floor(t / 0.26)
            local dt = t % 0.26
            if dt < 0.16 then
                local baseF = 2400 + ((noteIdx * 430) % 1100)
                local chirpF = baseF + 650 * math.sin(pi2 * 14 * dt)
                local env = math.sin(math.pi * (dt / 0.16))
                val = math.sin(pi2 * chirpF * dt) * env * 22000
            end
        elseif sfx == "phone_ring" then
            local cycle = t % 1.15
            if cycle < 0.72 then
                local mod = 0.65 + 0.35 * math.sin(pi2 * 20 * cycle)
                val = (math.sin(pi2 * 440 * cycle) + math.sin(pi2 * 480 * cycle) + 0.35 * math.sin(pi2 * 880 * cycle)) * 0.42 * mod * 25000
            end
        elseif sfx == "scream_female" then
            if t < 1.50 then
                local f0 = 880 + 180 * math.sin(pi2 * 0.9 * t) + 22 * math.sin(pi2 * 6.5 * t)
                local env = math.sin(math.pi * (t / 1.50))
                val = (math.sin(pi2 * f0 * t) * 0.55 + math.sin(pi2 * f0 * 2 * t) * 0.3 + hp * 0.15) * env * 26000
            end
        elseif sfx == "scream_male" then
            if t < 1.55 then
                local f0 = 420 + 95 * math.sin(pi2 * 0.8 * t) + 16 * math.sin(pi2 * 5.8 * t)
                local env = math.sin(math.pi * (t / 1.55))
                val = (math.sin(pi2 * f0 * t) * 0.55 + math.sin(pi2 * f0 * 2 * t) * 0.3 + lp1 * 0.2) * env * 26000
            end
        elseif sfx == "scream_horror" then
            if t < 1.65 then
                local f1 = 590 + 160 * math.sin(pi2 * 1.1 * t)
                local f2 = 635 + 140 * math.cos(pi2 * 1.4 * t)
                local env = math.sin(math.pi * (t / 1.65))
                val = (math.sin(pi2 * f1 * t) * 0.4 + math.sin(pi2 * f2 * t) * 0.4 + hp * 0.3) * env * 27000
            end
        elseif sfx == "crying_female" then
            local sobPeriod = 0.62
            local dt = t % sobPeriod
            if dt < 0.38 then
                local f0 = 540 - 85 * (dt / 0.38) + 14 * math.sin(pi2 * 6.0 * dt)
                local env = math.sin(math.pi * (dt / 0.38))
                val = (math.sin(pi2 * f0 * dt) * 0.6 + math.sin(pi2 * f0 * 2 * dt) * 0.25 + lp1 * 0.15) * env * 21000
            end
        elseif sfx == "crying_male" then
            local sobPeriod = 0.68
            local dt = t % sobPeriod
            if dt < 0.42 then
                local f0 = 265 - 45 * (dt / 0.42) + 10 * math.sin(pi2 * 5.2 * dt)
                local env = math.sin(math.pi * (dt / 0.42))
                val = (math.sin(pi2 * f0 * dt) * 0.6 + math.sin(pi2 * f0 * 2 * dt) * 0.25 + lp1 * 0.15) * env * 21000
            end
        elseif sfx == "night_insects" or sfx == "forest_night" or sfx == "village_night" then
            local pulse = (math.sin(pi2 * 20 * t) > 0) and 1.0 or 0.15
            local env = 0.6 + 0.4 * math.sin(pi2 * 2.2 * t)
            val = math.sin(pi2 * 4100 * t) * pulse * env * 16000
        elseif sfx == "heartbeat" then
            -- Realistic deep human heart "Lub-Dub" thump (never an electronic beep!)
            local dt = t % 0.72
            if dt < 0.16 then
                local f = 62 * math.exp(-dt * 4.5) + 38
                val = (math.sin(pi2 * f * dt) * 0.85 + lp2 * 0.25) * math.exp(-dt * 16) * 29000
            elseif dt >= 0.21 and dt < 0.37 then
                local dt2 = dt - 0.21
                local f = 76 * math.exp(-dt2 * 5.0) + 42
                val = (math.sin(pi2 * f * dt2) * 0.75 + lp2 * 0.20) * math.exp(-dt2 * 20) * 24000
            end
        elseif sfx == "glass_break" or sfx == "water_splash" then
            val = (hp * math.exp(-t * 10) * 0.7 + math.sin(pi2 * 3500 * t) * math.exp(-t * 14) * 0.4) * 27000
        elseif sfx == "rain_drip" then
            -- Delicate soft water drops ("ٹپ... ٹپ... ٹپ") with realistic upward bubble pitch chirp
            local dropTimes = {0.12, 0.68, 1.15, 1.78, 2.32, 2.75}
            local dropFreqs = {1150, 1380, 1040, 1460, 1220, 1310}
            local dSum = 0
            for idx, dt0 in ipairs(dropTimes) do
                if t >= dt0 and t < dt0 + 0.055 then
                    local dt = t - dt0
                    local f0 = dropFreqs[idx] + 520 * (dt / 0.055)
                    local env = math.min(1.0, dt / 0.003) * math.exp(-dt * 75)
                    dSum = dSum + math.sin(pi2 * f0 * dt) * env
                end
            end
            val = (dSum * 0.85 + hp * 0.03) * 24000
        elseif sfx == "tea_sip" then
            -- Gentle warm tea sip (short soft airy draw 0.10-0.52s) + delicate porcelain cup clink at 0.78s
            local sip = 0
            if t >= 0.08 and t < 0.54 then
                local dt = t - 0.08
                local env = math.sin(math.pi * (dt / 0.46))
                sip = (hp * 0.35 + (lp1 - lp2) * 0.45) * env * 0.55
            end
            local clink = 0
            if t >= 0.78 and t < 0.94 then
                local dt = t - 0.78
                local env = math.exp(-dt * 42)
                clink = (math.sin(pi2 * 2680 * dt) * 0.45 + math.sin(pi2 * 4120 * dt) * 0.25) * env * 0.42
            end
            val = (sip + clink) * 22000
        elseif sfx == "wind_breeze" then
            -- Soft, airy gentle evening breeze (band-passed whisper, never a harsh low roar)
            local mod = 0.65 + 0.35 * math.sin(pi2 * 0.35 * t)
            local airy = (lp1 - lp2) * 0.75 + hp * 0.18
            val = airy * mod * 13500
        elseif sfx == "leaves_rustle" then
            -- Crisp, delicate rustling tree leaves
            local flutter = 0.55 + 0.45 * math.sin(pi2 * 2.8 * t) * math.cos(pi2 * 1.1 * t)
            val = (hp * 0.55 + (lp1 - lp2) * 0.25) * flutter * 15500
        elseif sfx == "rain_light" or sfx == "rain_indoor" or sfx == "rain_roof" then
            -- Gentle rain drizzle / light pattering
            local mod = 0.85 + 0.15 * math.sin(pi2 * 0.6 * t)
            local pat = (sfx == "rain_roof") and (hp * 0.45 + lp1 * 0.55) or (hp * 0.40 + (lp1 - lp2) * 0.45)
            val = pat * mod * 15000
        elseif sfx == "stream_water" or sfx == "sea_waves" then
            local waveMod = (sfx == "sea_waves") and (0.45 + 0.55 * math.sin(pi2 * 0.28 * t)) or (0.80 + 0.20 * math.sin(pi2 * 1.4 * t))
            val = (lp1 * 0.65 + hp * 0.28) * waveMod * 16500
        elseif sfx == "dog_bark" then
            local bTimes = {0.08, 0.55, 1.05}
            local bSum = 0
            for _, bt in ipairs(bTimes) do
                if t >= bt and t < bt + 0.22 then
                    local dt = t - bt
                    local f0 = 320 * math.exp(-dt * 6) + 165
                    local env = math.sin(math.pi * (dt / 0.22))
                    bSum = bSum + (math.sin(pi2 * f0 * dt) * 0.6 + math.sin(pi2 * f0 * 2 * dt) * 0.3 + lp1 * 0.25) * env
                end
            end
            val = bSum * 24000
        else
            -- Soft neutral air fallback (never a loud pulsing roar)
            val = (lp1 - lp2) * 0.35 * 9000
        end

        local s = math.floor(math.max(-32767, math.min(32767, val)))
        if s < 0 then s = s + 65536 end
        local lo = s % 256
        local hi = math.floor(s / 256) % 256
        chunks[i + 1] = string.char(lo, hi)
    end

    local rawPcm = table.concat(chunks)
    local fos = FileOutputStream(File(outWavPath))
    writeWavHeader(fos, #rawPcm, sr, 1)
    fos.close()

    local wf = io.open(outWavPath, "ab")
    if wf then
        wf:write(rawPcm)
        wf:close()
    end
    copyFileBinary(outWavPath, publicSfxDir .. "/" .. sfx .. ".wav")
end

-- Native Android MediaExtractor + MediaCodec decoder
local function decodeMediaFileToWav(inputPath, outWavPath, maxDurationSec, skipStartSec)
    local inFile = File(inputPath)
    if not inFile.exists() or inFile.length() < 100 then return false end

    local rawPcmPath = outWavPath .. ".raw"
    local decodedRate = 24000
    local decodedChannels = 1
    local success = false

    local ok = pcall(function()
        local BufferInfoClass = luajava.bindClass("android.media.MediaCodec$BufferInfo")
        local extractor = MediaExtractor()
        extractor.setDataSource(inputPath)
        local numTracks = extractor.getTrackCount()
        local audioTrack = -1
        local format = nil
        local mime = ""

        for i = 0, numTracks - 1 do
            local fmt = extractor.getTrackFormat(i)
            local m = fmt.getString("mime")
            if m and m:find("^audio/") then
                audioTrack = i
                format = fmt
                mime = m
                break
            end
        end

        if audioTrack == -1 or not format then
            extractor.release()
            return
        end

        extractor.selectTrack(audioTrack)
        pcall(function() decodedRate = format.getInteger("sample-rate") end)
        pcall(function() decodedChannels = format.getInteger("channel-count") end)

        local codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, nil, nil, 0)
        codec.start()

        local fos = FileOutputStream(File(rawPcmPath))
        local fileChannel = fos.getChannel()
        local info = BufferInfoClass()
        local inputEOS = false
        local outputEOS = false
        local maxPtsUs = math.floor((maxDurationSec or 5.5) * 1000000)
        local safetyLoops = 0

        while not outputEOS and safetyLoops < 1500 do
            safetyLoops = safetyLoops + 1
            if not inputEOS then
                local inIdx = codec.dequeueInputBuffer(8000)
                if inIdx >= 0 then
                    local inBuf = codec.getInputBuffer(inIdx)
                    local sampleSize = extractor.readSampleData(inBuf, 0)
                    if sampleSize < 0 then
                        codec.queueInputBuffer(inIdx, 0, 0, 0, 4)
                        inputEOS = true
                    else
                        local pts = extractor.getSampleTime()
                        local flags = (pts >= maxPtsUs) and 4 or 0
                        codec.queueInputBuffer(inIdx, 0, sampleSize, pts, flags)
                        extractor.advance()
                        if pts >= maxPtsUs then
                            inputEOS = true
                        end
                    end
                end
            end

            local outIdx = codec.dequeueOutputBuffer(info, 8000)
            if outIdx >= 0 then
                local outBuf = codec.getOutputBuffer(outIdx)
                if info.size > 0 and outBuf ~= nil then
                    fileChannel.write(outBuf)
                end
                codec.releaseOutputBuffer(outIdx, false)
                if info.flags >= 4 or info.presentationTimeUs >= maxPtsUs then
                    outputEOS = true
                end
            elseif outIdx == -2 then
                local newFmt = codec.getOutputFormat()
                pcall(function() decodedRate = newFmt.getInteger("sample-rate") end)
                pcall(function() decodedChannels = newFmt.getInteger("channel-count") end)
            end
        end

        pcall(function() fileChannel.close() end)
        pcall(function() fos.close() end)
        pcall(function() codec.stop(); codec.release() end)
        pcall(function() extractor.release() end)

        local rawFile = File(rawPcmPath)
        if rawFile.exists() and rawFile.length() > 400 then
            local rfCheck = io.open(rawPcmPath, "rb")
            local nonSilent = false
            if rfCheck then
                local rBytes = rfCheck:read("*a")
                rfCheck:close()
                if rBytes and #rBytes > 400 then
                    local sByte = string.byte
                    local step = math.max(2, math.floor(#rBytes / 800) * 2)
                    for bi = 1, #rBytes - 1, step do
                        local lo, hi = sByte(rBytes, bi, bi + 1)
                        if lo and hi then
                            local v = hi * 256 + lo
                            if v >= 32768 then v = v - 65536 end
                            if math.abs(v) > 220 then
                                nonSilent = true
                                break
                            end
                        end
                    end
                end
            end
            if nonSilent then
                local rawLen = math.floor(tonumber(rawFile.length()) or 0)
                local wavFos = FileOutputStream(File(outWavPath))
                writeWavHeader(wavFos, rawLen, decodedRate, decodedChannels)
                local rawFis = FileInputStream(rawFile)
                local copyBuf = byte[8192]
                while true do
                    local rLen = rawFis.read(copyBuf)
                    if rLen == -1 then break end
                    wavFos.write(copyBuf, 0, rLen)
                end
                rawFis.close()
                wavFos.close()
                rawFile.delete()
                success = true
            else
                rawFile.delete()
            end
        end
    end)

    pcall(function()
        local rf = File(rawPcmPath)
        if rf.exists() then rf.delete() end
    end)
    return ok and success
end

-- Embedded Real 8000 Hz Unsigned 8-Bit PCM Recordings (Morning Birds + Real Scream)
-- Decoded in pure Lua directly to 24000 Hz 16-bit WAV with ZERO MediaCodec dependency!
local EMBEDDED_BIRDS_U8_B64 = {
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgIF/gICAgICAgICAgICBf4CAgICAgICAgICAgICAgIGAgICAgIGAgYCAgICAgICAgICAgH9/gIB/gYCAgICAgH59",
    "g4F8gIJ+f4J7foN7f4N9f39/f4CAfn+Cf36CfH2Ee4GBfYF8gnx9hXuAgn1+f4GBfYJ+fYR9gn6Agn6Cf4B9g4J7hIJ+g4GAgYCFfoOBgIKBgYGBgICCg3yB",
    "hXuDhHuBhXyBg4B9hYF8hYF9g4N/foZ+fod8f4Z8gYKBfYCFe4CGeYKDeYV+gICAgIF9hXiGfX+Ee4J9hHx+g32Agn1+gn18iXiDfoB+foN5goV2hnx9gn6A",
    "e4Z7fYV4hXuGd4Z/eoV4iXaGfYV3inaEgIF9hnqAg3qEfoKDfIGDe4V7iHiKeoKDgIB/hX+Efn+IfYGGfYaBgIV9hIZ9g4Z+hIOBfoqCfoeBgIaCfoiBgoKD",
    "hXyIgn2Ig36Gg4CDhIN7jXqEgYhzmGuUd4p6hYlzjnyBgIZ3jHaJeYZ+foN9hHqGeYV+e4R9gHyAgnp9h3SDgHt/gH19gIN0iHx4hnt8gn19foF+eYd7fYF/",
    "fX6BfH+CfH+CfYF+gn1/g3uDf4F8iHiEgH6DfoKAgH+EfIGFeIp5h3eNdIiAgXqRbZF5hnqLe4CKeYd+iHqGhnqHhH2EhICBhoN7i4F8iYJ9hYZ7h4KAgYd+",
    "gYWDeYx+fIt7hYCDf4OBgYCAg3yEgIF8h3uBgH+AfoN7gn5/foF/fIF+fn+AfX5/fn99fn99gH5+foB8gIB7gX2BeoJ9fn+CfH2CfH+AgneGgHmFf3uBg3x/",
    "gYF7hX99gIJ9gYJ/fIZ/fYV9goCCf3+DgX+Bg32DgYF9hnyChHuDgn6AhX2BgIR9gIN9goJ+gYOAfoSCe4SDfIKBgICCfoCDgH6Cg3yDgX6CfoCBf4F/f4N9",
    "gYF9gn9/gH+CfYGBf36Bgn99g4B8hH1+g359g4F6g4J7goJ7gIR6gYN7foZ8fYSAe4V+eoZ/eYeAeId+fIODdoOJcYaHc4OLc3+NdnyMfXSMg26SfHWLh2yO",
    "hXKEkWqIj2yGkm6AkXZ2nG56mnF7kX1wmX5lpXNxlnx1h5BkkI1mkYR4fpBze5hshoZ8fY51f492f4p/dZN1f4p+cpZ4dZR0fYp9eIiBc418eYWDcop6fYN6",
    "fIV5f3mKboaAcotwhnx0k2CXc3WRZ5JtgpJOvkOffGmiUK9egZ1KulKVhmC3RKiBWcI7t2xxsULBWIWqPclRjaJEwVuQiGW6Q6qCYL4/sH1ktUO/Ym7DM8Fn",
    "cL8xx15+si3iQI2xLOM7mZ1E2Ci8ji/2ILGSPeEov3Fa3RjFhD/pDuNQcsMpzF1rzBvdR4W1ItxPcsAm0VZwwCjPU3a+JspjZsEwvmRzq0K5ZGy3QKx0aqtS",
    "nXptpVGjeWuhXpp0c6Fbl3tznF2ZfW2eYZV8dJFwj2+Ii2KecXmWZpR0hX56kWmRfnGYaox9fYlwlHR5mWKUf2ygY4qOXapfiJFeom92nGOTdoOKYbRNkaor",
    "zHdA1FxorHRuiadBmroYwKYdxo1Kn5NmdbZVbstDebxRg5N+bYuTX4ySaXqbdly0dk25elCpiFKZmFGMoVl+oGxqoH9dmJBchqJZfqtVfqlaf5l1a5SQU5ae",
    "Rp2SWJSHcH+LgGibfWOoa3OfZot/fYxrm3F2oGOIj3KDg4Z2g49ojo1jkI5pho91dJV+aZaFZJx7bJp9bYuPY4qbXImcY4OPeHGXhl+bk06clliFpGpitnFV",
    "sYJOpY9cfqJzXax+VaSHXZKJdm2ibW6gcnSUdX55k2x/mGKSfnCTa450iIFxknZ2jH9ziYB+cZpwd5J8bZd3dYyAdIKSZIaZYX+hY3yWdnGOimWKlmGHknJ2",
    "lXtxj4Rwi4ZziYN6hn6FfIKIdYSQaY6MbIyEf3mLh2qVgXSIh316ioRziod0hol0hoN+gX2LeHmZZI2Gcop5iHWFgYJxknp0jH2AcZtlin9/fIZ0jnKFf4B9",
    "fIt0fY10fYx1gX+IdH+RbIGPc3qOenmEhnd+j22IhHWIfoB7hYVyiodujX9+e4x5fIiBeIeDen6Od3qTdnqSdIh8hIltkoZnn3GFhHyQaJx3dZ1ojoJ9hYGC",
    "gIGJdomDe4aCgIKBhH+DhH6EhneJhnWJgYN3jIJ2iYN5h4CCe4mAdo5/d4aFfXmLgHWJgHyBgIV3h4F3i3eFf3mOcYWEeYN4jXV6l2WOg3CUbIt/c5ZqhI1r",
    "jHqGenmTaoSMboaEe396jm9+kmuFhXl/foV1hIVwjH16f4KCc4p+d4d9eYaAeIGLb4SLcYKHfHqJf3iHhHKIi26GjnR8jnx6h4Z1iIhxiYt0gY98dY+EcYiL",
    "dIGMenmPgG6ThGyPh3GGiHl9jnl6jX17gop2gY1yhoV6h3uGgXWPfHuEg394jnZ/iHeHe4N/d452eZFygIKAfHuNcYCNboGMcIOCgHiCimyHim6IgHx+gYVy",
    "i4BzjH54iXuDeoWEcJR4d5NwhoR6iHiJfHuSbYuJcJF4hIN+jG+UfnOSfX+DhoVylXh8j3x+in98inuJdpB6gYZ9hIN9hX6Ff4GCg4F+gIp4hIN/h3ORcomC",
    "eoKIeXqOdoR9g39+gH2Ef3iKd4N/e4CCgHCQd31+hH51jHV/hH51in15fod6eYp5e4l3gIKAeIWAeIKEdoKFeIGAgHt/hXmBgXyDfH+AgH2AgH9/fYN+fIR+",
    "fYR9gnuIen6Je3qMeIGCg3iHgXiIg3KRenyBjmyPeYtxiolrlnWEf4Z6hoGBfYSGeISKdIeEe4SDgHyKfXyJf3uGgnyDhniBj3B/l2qAk3F/iX92h4tlkI9d",
    "kY1qf5J1b5p4aKF0bpGGb3WvS5CVZ3aqWIGfZniYfGKke16nemKbjVOdlUyjhWmCnGZ2rll6qmRwqHFoo3luj5JbmYtlj4xwf5RxfpB5dJV9bpKFboWOcn+L",
    "eneSeHGccnWTeHyGfn6Gf3mMfn2Df410g416gYSHfIOLco+FbpeAcpN+e4qAgXqRdHuZZoyKa5F4goFwmWl8mlace2mXa49qg5dNpHhhq1iLiWKhV5aFWKxf",
    "gJdZnG97llehc22gW5OBY6RhhY5imXN0mGORfmqfY4uIYqRlf5dcnnB5lmGbcnSlU5qEY6ZhkIBuo1iXjFWxZX6WZJ1riY1bsWN3qVWZgmydZpZ4b6pVkZJZ",
    "pm15m2KTeXySYpxzdaNSnINipGKMiGSkYImQW6Vtdptil3B5nVeaf2WsW4eVWp9wdp1bnnN1oFqWf2qgX5CJY6FpgpNjlHx1k2iTeHqSY5mAY6ZngZFllnh4",
    "lGeUfHCWc36EgHuIeoR/g3qBiWqbbnugYnuxQ5ihP6iVQrGCXJaWUZeeTIu6M43SC7azHLegQou4TmbYRVj2JXHlKIi1VYCRjFmVpzenqDCwlUuamVt9slxf",
    "1ktX7DVq3D5rzVdgu3dNtoZDuIdGsJBCrZJGp5ZCq45TkaRQhLNIhLdDibJIiqJidKpncKGAVKyMPb+BQsFwZ5GVXX60SnzCP4G9R3ywZWWpij62mifAmii8",
    "lEGgmV13tF5hy1VgzFdju2thoZBOlLA0nLUxmrBFgLdcXchpQdxjRs9wRr98Up2bTIytSoC8QIa0RY+UcXONk1CfkEqqfmOTiGuBkXhno3lar2xwlnl4hIJ/",
    "dox/cJJ3foCCh2iXhF6hfGeafXGKhnl1mnNrq2N5oGh+j39skZBXmpVRmpJfjJRrfJxudaFucKZscaVreZR+b46RWZuTT6WKWpmPYI+UaICXdmyjdG2fdnGW",
    "e3WPgHOMh22OiGmWfXKVdYCJdoeCeod+g3yEh3CPgnGQfHuJfICChHx8kHB+mmKLj22DjHt2jYNrkoZnk4RsjoJ1hYN+d4mFa5CDa5F/dIaFeHuJfHSOfXGO",
    "gG+LhW2KhnGDiHZ7jHhzk3ZzknV7hYB6d5B1dZZzdpRwgIR+fHyMcoCRa4iIcYiBgn6BiXWKgnSSeH2OeICEgoF8iX98in19jXqAhn6Bg4V7gop1hIx0hIh6",
    "fJJ1fJJ1gIqAcZd5d49+eIt8f4KFf3mLgXGWd3aXcIaBgnqDiHSJgHx+iHOIfYR5gIVzg4dyhYN1gX18hX97gHmGdod/do5tint5i3h9gnmFd4V9eol3fod2",
    "godzh31/gn+CeIl9eYt7foV8g3qKgHOTd3yMeIR/gohzjIVumXR9jXiFfod9fY50g45wjYB/fol+e4mAe3+WXKJwgYOGd4aEeId+gX+Ah3CVa490inl+jG2O",
    "fXmGgXeHeoN5hYFzj3Z7jXCIfXuGdIh8eYl5eY1xhYJ1jm+Jf3aIe399g356hn18goB/eYd+eIaBd4KLa46AdIiAeIWBeIh3iXOMdoR/e4pziIF4hoJ8fI9u",
    "jH59hXmJe3+Kc4mBfIKIdImDd4eCfIKCg3qGgX2Ah3x+iniAinaGg3qFgIB/gYR6h4B6i3eDhnaHgniJfX2FfIN6h3t9iXSEh26Pe3iIeYJ6goNwkHh0kHV3",
    "jnSAfYZ2fI5vfJFrg4dyg4J4fod3dpJ0cpZ3b5R5doaFdnySb3qXb3iUd3aNf3KLhm6JjGuIjmuIjHGEiXh/in9xkINqlINvi4pvgZVxd5x1b517a5iIYpmM",
    "YJeQX5OTYIyaX4WjXYOjX4KfZnyhbm+pb2uld2Wlfl6lg1qlg1qihFudiVybi1ibjVeakVOck0+ckVKbk1KXl1SPnlOIp0yHrkqHqlGEpl13qWZpsWphsmhm",
    "rGtsmX9ojZFgiZhWj5dUl4ljkINuhYV1fpFqiIxlkoBslHh1j4FslIJom3R7i319go1ygJdZn3xoql2Shm6cYp54bLFQoX1rrVGpc3CuTKxyc7FBu2xpuEKx",
    "a3+cT79TfrotwmxqqVeqV5iUOdlGero3tWh+l0/FPZmiL9FSfKZFvkeakzvTRIKwNb9cgJdTslOMmUS7XneiVpl1fIltlmmFjGWTenmCgYFwlXVymW58kW6M",
    "cpZmjopgpGx5mmmDkmeVcJJ0eK08v2Z1oGOXcYOcR8FmYc06nJlSrGWWd3G3ObGSNtpQeLBNp2yFllO4X3mtTKJ8cJthoWh+pUOze1DITn+pU46RbHapVYWj",
    "VYKtTX29PYPAO37NJZusQoW4QnvDQHHQPWfdPVT6H3HgLnXQNYmlY26ifFWpiT69e0a+c1OxdmCXjV98tz6B0xGpvhC+ni6ykE+Pp1B1yjty3SaFzS6OsFB7",
    "q2tftHhGx3JEzWxMwnNZpIxai6dTgbVNfrZUdrNkZrVvXq99WKeJWJeaV4yeZXemcWSueVumkEyepEWTrU9+t1psuWtbuXdXqYtUl59OjKtNg6xYeaRuZ6GA",
    "V6h8W6V1bZVxhnh+kGKShWOYdnqFeoxnjoxXon9do3NxjIJzeZpodKZkdZ9seJB/boqQZIibXI6YWZiNZo6LeXmWgGKqfFqye1mrhl6VmliIqld8tFtzr2lu",
    "o39gmJdZjqBVj5xfiZRwe5d3cp10c5tvgo5zhYKBg32FfoCGd453e5dtgJZtgpJtgJJ1eJJ6cZp4ap57apSGY4+RXYqeUo2XXoKZanSdbmqgdmClc2SfcXWG",
    "h29+jXRwnGl5lmiDh3WCfoF6g3uBhHGOeniKfnt+kGaOh3CDlGSLhnaEgIZ1hopkmXxxlHh2knKGfYd3h4J2hod0hoZ4hoCBfod8f4x1iIJ9hX+EgIOGd5B7",
    "fJNziYZ7i3uLeoWOcI2Ic4yGfIKJgnaNiWidenaReoR4jYJrnnRzm22DgoV1hYN9c5hniIdvkG6OdX6EfnKUZ5Byhn12ind7hnt4iXWCe4N5gIF6gX2AfH6B",
    "e4B/fn99hHl/h3GMeX+DeYd6fopyhoVzioB6hn6CfIOGco5/dZB4gYSAgX+EgXyGf4J/hYB8iIB8h4CAfox5gIt8e5B3gol8goGIe4GRa5KDc5F/d4+BdJF/",
    "do9/eIyBeYiEe4KGfX2KfXyLe32Hfn5/inKHhHaIeYR9e4txhYZxh4N2g4B+eoR9eIh3foN6gnqBhHCMe3eKdYV8foR1iX10kHSCgnqHdoiAc5R0epRvhIZ7",
    "hXqKen6Nc4eGeoV/hnuDh3WMgHmMfX2JeYt5g4h3jHqCiHeIg3qIfISCe4p6gYl3hIZ2iYF5hYF/foR/fIZ+e4Z9foJ+gniLeHqNdICFeIR9fIZ3hnx6h3x9",
    "f3+CfIB8fYd2fYh3fYR9eoR9fH+Hd3yLdX+HeH2IfHmEhHSKgW+Pg3GKg3aDh3x5jnp2knd7i3t8h4N4hYlzhYtzh4hziYh1hIl3gYx6f4x9fIqAeYt+fIx9",
    "gIaAgIGFgICKfX+IgIJ+iH9+jnWDi3GNf3ePeYd8fY5yhYd1i35+g32Gd4aFc458e4p6gn+BhHmHfXyLenuGf36BhHiBjHJ+jHV7iH1ziYZqjYVnjoFsiYVy",
    "gIxzeI90dZB1c5F6b5F6co58dYaCeH+Gc4OHcoWAeYN9gHuDfnaOeHqPdYGMdH+JfHqIgHePfnWPfnmJf36EhH5+i3t+j3aBi3SIh3mEhIF+h4J5jn54jX57",
    "hoF6god2god0hoZ1hYR4gIV9foR9fYd9eoR/e4B/fYCCe32CfXyBfnuFfXeHf3eEf3iBhHd+inR8h3OCgniDe4F+e4d4foV4gYKCe36IdIWGcox9d4t3g4N4",
    "h3x+hX2BgIR8fYx6fot7f4h/e4mGcoaMcoSMdISNdIGPeICLe4KJfX+FhXyChnmHhXWKhXmGg36DhXuBi3aBjHOGhnWHhHuBhYF7h396iX17hoB8f4N/fYR9",
    "fYV/fIOBfIOAeoV/eoR8foR8fIV+e4R9fYZ6fYZ6f4J+fH+Ce36Fen+EfHqGf3SKfnSMe3eKfHiFgnSHhHGLgnGNf3WHg3aDiXWCi3KEjXGBj3SAj3R/jnd+",
    "in17iIN2iIZ0ioN4iIB7hIR9f4Z8hIZ2h4R3h4R4iYR3iYZ3h4J9g4WBfYuAeY1+e4t9gYSChH+EgX2Dg36Ah35+i316iIN6hIR7goZ7fYd/eYeDdoWFeIOD",
    "d4KEd4KBfIB/fYN9eYSBeIJ/doV/dIaBd4CAf3iBgXeFf3aGfnqBgIF6goN6gn99hX98f4SBe4WAf4R+g4J8g4KAgoCChYB+hYJ/g3+Dg4CDgISBfYZ+goN5",
    "iIN6hn9+hYF+fYh/eY6AeIx7fol8fYiDeoOFe4OCe4aDeYOGeYKFeoSDeoSEe3+GgXqGfniLe3mJe3uDfn58gnt/hneAg3qFfHuFenyCfn2Af3uCf3iCgnh8",
    "gn58gXx9g358gIN9e4V+fIR6foR8fYCBfX2EfH+CeoSCeoN/foJ9gIB9gXyCgXeFhHmGgHuHgHyEg4CAhH+Ah3qCiXqEhH2EgX+DhH9+hoB/hX2Bh32AhIF9",
    "gIR9g4N2h4N3hn9+gn2Dfn6BfYCCf35/g3x9g3mAg3mAgH19foF5gYB4hXx2h314g314goN1f4Z1f4Z1goV3goR8foR/fIOBeoOBeoWEeYOAfYR9f4R/gIB+",
    "f4KBeYSDeYWBfYSAfoGFf36GfX+CfYSDf4CEhHyFgX+JfYCHgIJ+hIR9hoCAh39/g4SAg4Z7h4R6iX5/hnyFg36CgoV+gYZ+g4N9g4KAfoGGfICEfYGDf4KF",
    "f36Fgn+Dgn2Cg3qDg3uBgH6Bf4CBf359gn9+gnx+g3x+g4F8goN4g4V1god5fISBeoOAeYZ+eoOAgX9+gX6CgX2BgH9/gIF9gIF/gX+BgYKDfYKDfYJ/f4R+",
    "f4F/g4CBf4CEe4GGfIWCfYaBfn+DhXyBgn2GgX6EgIKAgIR+gIKAgX+DgICEfYCGfn6DgX6CgX6Cf36Cf36AgH+Afn+Df36FfX6FfHyEgXp/g3qAgneBhHp/",
    "f39/f356gYB6f36AgHt/gHx+gHx8g3x6g317gXt8gn95gIF9gn59hH5/gXyCgH6Af39+gIB8g399hnx/hH2DgH+Df4CAg4F/hn2BhnyChIB+hIV8hYR4iIN6",
    "hoGAg4KBgYV9foV7goR6hYF9goCAfoR/eYh9eYd9fYV/fICFen2Ge3+DfH+CgXqAhnmBgnmDgnx+gn98gYB6g399g31+gX1+gIF9gIF5hIN6g4B8gYF9gIR8",
    "gIR8gIB+f4CAe4GAfIN/foGAf32Bfn2Den+FfIKAfoJ/gH6Dg3qEgX2Ef3+BgoB+hYB9hn58hYF7g4F9g4F9gYJ+gIV+f4Z8gIR7g4N/gYODe4SDeomAe4iA",
    "gISCgYCHfoGHe4SCfIaAf4KDgn6HfoCKeIKIeYSBf4N/gnqDg3mFf3yFfYB/gIB7gn1+g3mBgXyDfX2DgHx+g3t/hHeAhHl/gnt+hH17hH57g399gIF+foF9",
    "foF/f3+Af36CfoCCf3+Ag35+hXyChXqFgX6Ef4OAgoR8hYJ+hX6BgoGCfod/fod8goN+g4KAgYSAgIR9hIR8hIKAgYCDfoGDe4OBfIOBfn+Cf32FfnyDf4GA",
    "f4B9g358g31+gH2AgIB9gYB8gn59gX6Afn6Afn98f4B7gX97gX99f4J9foZ7f4Z9foN8foV+fIR/foWAfYKCfoKDgIKBfYOBf4OBgYKCgYKFfYODfoSBf4OC",
    "gYGCgYGDgYGEgIKDf4KBf4KCgIGDgICBf3+DgH6EgICCf4CFgH+DgIGDgIGCgYGBgn6Bg36AgYGBgICAgoJ+gYKAgX5/gX9/f3+AfYGAfIB+fn9/gH+Cf36B",
    "gYF/gICAf3+Af39+gIB9f4B+gX18gn96gXx+gXp+gX19gH99fn9/gH5/fn+AfYKBfX2Af3+BfIGEfH2Cf36AfX+EgX6Eg3yChX6BgoCDgX6BhYF+hICChIGC",
    "hYGBhYOAg4CChX+AhYR9g4KBhIKBg4GAgYSBgoGCgoCBg4GAgoCCgn6ChH2AgoJ/f4F+hIB6hIB+gIF+f4F+goB7goF+f35/f35+gIF8foF/fX5/fn+AfIKA",
    "fICAfYF9foF/f32Af3x/gIJ7f4N+g4B9g4B/gIJ/gIJ9gYB+hH9+goCAf4GAfYR+gIR9goOAgIODfoOBf4N/gIOAgH+AgYGBfoKDf4GAgYKAfYGCf3+Af4OA",
    "f4GBf4J/f4N/foGBf36Bf36Df3uEfnyDfnyAgXx+hHuAhHmBgnt/f31+gIB8f359gH99f4GBfYF/foF9f4F9gH5+gICAf4F/gIJ+gIN+gn9/gX9/f4CBfoF+",
    "gIN+f3+BgYCAfoGDfIKAfYGBfYKBgICDgn6Ef3+DgICDgYF/gYCCgYCAhH6BgoCAgoCBhH2CgoF/hH6DgYGBgIGBgIGCgoF/gX6Cgn2Ag3+DgH6BgIJ+goB9",
    "gIB9goB+gIF/fYN8gIB8gX5+foB+fIB9fYF9fX9+fX5/fYB/fICAeoF9f4J8gX5+gXuBgH+CfYKBfoJ7g39+g3yDf4CEfYGDe4Z/foGBgoCAgX+EgnyFgX6F",
    "f4CFgYCDgYB/g4J+hICAg4J/hIKBgYJ/goR9goN/g4GAgYKBgYGDgISAgYJ+gYGAgIN+g4GCf4F9gYJ7gn+Cfn6BfYB+foGBfYGAf3+BfH6AeIJ9fYF9foR7",
    "fn58gHuBfoB/f32AfH9/eYJ9foB/foJ6fIB7f3x/fX99f36AfH6CeoJ/foCBfYB+foJ9gH6Ce3+Cf3yCf36GeoCCgH+Af4CBgIB/g36CfoOBgYCAhYKCgIGE",
    "gYCDgYOBf4aCg3+HgX+DgYKGgH2FgX+AhH6Ff36Fg39/hICCgH2Cg3uAg36Bf36Agnx/gn99gIB8gH57gIB6f39+fYB8foF9fYB/fH9/fX6Be4B/fYF+fn9+",
    "fn5+gXuCfn6Bfn1/fn9/fn6Ag3uBf3yCf39/gYF9gIF7hH19hX6AhHyCgn6EgIGBgIJ/gYJ8goB9gn6BgoGAgoKAhIN9hYJ/g4CDgYKDgISEgIaAgoV/g4WC",
    "gIOCf4KCfIR/gIN+gYCAf4CBf3+DfoGBf3+Bf3+Af4CAf4CBgIB8gH5/gIB/gn5+gIB+f4CAgICCfoGCfX+EfIKBf4GAgYB/goF+gn2CgX+BgoGCf4KBgIN+",
    "gIKBf4F/hIGBfoODgoCCgYOCfYGBhICCgIWAgH+Ff4GCgYKEgYGFgYGDg4CGf4KEgoKFgoODgYSEgYCFg4SDg4SHfoKEg4GCgIOEgICFg4CBgYSBf4SAg4B+",
    "hn+Ag3+AhH2AgoF9goF/gYB/gYGAgICCfIKBfYGCfIOCe4KBfICBfoGCfn6CgH2AgX5/gYF9gn9/gYGAgX+BgYB+f4N/gn+AgYF/goCBgYKAgIGAgICDgYKC",
    "gIGDgIGDgX6CgX6Cgn6BgoCBgIB/goF9gYN/f4GAf4B/f4B/fYGBfIF/e4CBfX9/e3+BfH+AfX9+e358gH97gH57f397f3l9f359fH18gH99fX57fX9/fX57",
    "fIF+f3x9f35/gX19gH5+gX99fn9+goB+fH2AgIF/fH5+fYF/fX5+f4OBfH1+f4KCgHx8foKEfX5/foKDgH19foGDgYB+e4KCfoF+fICDgoB9fH+DgIF/fIGB",
    "goWAfH+CgYKCfX2Dg4OCfXyAg4GDfX2AgoWCfn1+goWBf3yAgIKDf319gIKGgX17f4OGgX19fIKFg317e3+DhH97e32DgoF9en2DhIF+eXuBgoOAenp/g4KB",
    "end+goKDfHl7f4KDf3l6gISEgXx5fIOFg354eoCFhX96en+EiIN6fH+DioZ+fH6Bh4qBe3x+h4eDfnp+goeIf3t6gYaJhnl7f4SKhnx6fIOIiYF5fH+HiIV8",
    "eXuDiYh/enp+h4eBenl6hoqGfXh4gIeHg3h3fIeJg3t2eYKGh4B2dnyFiYN4dneAh4Z9dnV9homDeXV5g4eHgHh3foSIhHt2eYKIiH53d32Fi4V9dneCiImD",
    "eHd+hYqHfnd6gYiNhXl5fISMiYB3eX+JjoN6d3iEjYh+eXl8i46EfnZ5hYyLf3Z3f4qNhnt0eISNjIJ3dn+Kjod9cnmEjIyBd3Z9iIuKfHR4gYyMgXdyeoaK",
    "iH11dYGJioJ6dHmDi4l/dXV8h4qFenV5gIqKgXd1e4WJhn14d36KioR6dniFiYaCeXZ9hoiHfHR5gIiJgXt2eoOKh4B6eH6FiIZ+d3mCiYmFe3p+g4iIgXx5",
    "f4eKhn97eoKJiIV9enyCiYeCfHp/hYmJf3p7gImKhH56eoCLiYF9d3uGioeCeXV9h4uJgHZ4f4mLhXpzeIGJi4J2dHmEjIl+dXN7iIyGe3RzgIuJg3dxeYOK",
    "in5zc3uFi4d5cXZ9h4yCdnJ2goyKfXVzd4aNhn10dICIi4V4dXmAjIqDeHN8g4uLf3dzfIeMiXx0eICJjYZ6dXiAiYuCeXZ6g4qKgHd3e4SMiX54d32HjIV8",
    "eHiAioqDe3Z6g4uJgXh3e4SJh4B4d36HiYd8dXmAiYmDe3V4hImJgnd0e4SJiH90cn6Fiod5cnZ+h4qEdnF4gIqLfnRzdoKMiHtzcnyHi4V6cXN/iouDdnF3",
    "hIqIgXRyeoOLh3xzdH2HjYd4dXZ/i4yDeXR4go6LgXl1fIiOioF4dn2JjYp/dXeBiY2Ie3Z5gouOhXh1eYGLioF5dHyGi4qAeHd8h42JfXZ1foqLhXx1d4KL",
    "i4N5dnqGi4eBeHN9houKfnR2f4mLhnt1eoGKi4N5c3mBi4t/d3Z5hYqHfnVze4eMhXxydX6HjYV4dXSBi4qDd3N3g42Kf3Rxe4aMiXxzdn2JjId3cnd+iY+C",
    "d3R3go6MgXhzeoePiIB2dH2Mjoh9dXWCi42IfXJ5hYyPhHl1eoeOjYR3dHqJkIuAdHV9iZCIe3N1f4uPhXdzdoGMjIJ1c3mEjYp/dHF6iI+IfHRzfYqNhnpz",
    "dYCMioJ4cnWDjIyBd3F5hoyLfnR0e4iMh3pxdH2KjYN5cXWDjY6EeHJ3ho6LgnRxeYePin1ycn2LkIh5cXJ/jI+EdnB1g42Ng3RweIaRjIFzc3yIkYp8cnR/",
    "ipGIe3R1go2Thnd1d4aPjoN0dHqJkYuAc3R+jJKIfXN1gYuPhXhzdoWNjoJ0c3mIkIt/cnN8ipCHenFygIuMhXdwdYKMi4J1b3eFjo1/dHB7h42IeXFxfIqO",
    "h3dwc4COjIJ2cHiEjot/dG96iI6MfXNxfYmNiXpxdYGMj4Z1cnaDkY+CdG96hpKMfXVwfIuSjHp0dICQkIp4b3aCkY+FdW55iJKOf3NxfIyTi31ycn+OkYd4",
    "cXaEkZGCdXB4h5CNgHJxfIuSi3xyc4CMj4Z4bnWCjY+BdXB4h5GOf3Jye4qQi3twc3+PkYZ3bnaEkI6CdG56h4+Oem9we4yOiXdtc3+Pj4N0bHeEkY19cm18",
    "jJGLe29xgI2RinZvdoKSkYNycHmGlI19cW98jZKJeXBxgo+PhXVudoWPkH9xcHmKkox7cHN/jpCGeW93g5CRgndweYmQjn9zdHuMj4p6cXaAj5CFd3B3hZGN",
    "gHZve4iQi3pzcH+NjYl3cnWAjoyEdnB6g4+MfXNye4eRiHl1c3+LjoZ3cnSEjYuCc3F5ho+LfnFyfYmRh3lxdYGMj4J0cHeGjox+cXB6ipCJeW90gY+PhHVv",
    "eIaRjn5xcn2NkYd6cnaBjpGCdW93iJGOe3FyfYyQhnhxdIGOkIJ1b3mJj4t+c3N/iZKKeHB0g5CRgnN0eoiSjIJ0cX+PlIV4cnaFjJCDc3B4i46Ie3VvepOO",
    "gXNyeYCOj4BwbX6JjIh6dG5/ko2Bc3V2gJCPgmtxgYuMh4BxboGSkX92cnKFlJF6bnR/io2Re2lyhpSMgndwdYeVj3lvcoKPj454aW+Mloh/dHFzi5mNdW51",
    "go2PiXdsbIyXjXtvc3qPkoh3cXN+k5Z/cG57i42MfXFrfZaRhnFveoeNi4VwbHqOlodzb3SJi4mJeGpukpiFd3F6fYyRhnVtc4SYkHdtcoKLjIx5anCIk4yA",
    "a22FiomOgGdui5KMfnhyc4mXi3VudYCOi4d5Z3WSlIV2eHh9hpKNcGp7i46JfnFxfo+ShXVxeoyJjoRvbYGUiYN/dG6FmpF1bniDiI2LenFohp2Tbm19hoGP",
    "k3hidZaTiHZ4cnqQmYZsb3uNj498bmaCnZB4bnx2fpKhc1xxlo2Eg3xsapChiGVve4GEl4ZmY4WUiYJ5b2qEmI9va3V9iZGGaWd8i4yMcWhxjYuIf3Ble5qS",
    "c3B5doKTkWxpeYqIi39sa4mShX2Ab2mRooNgeIp8gJyKXmqXkYCFfmpzm5Z6dHx4fpeTdWmAjoWOiGxtjZWBhIBreZiRdneCdn+XkW1siIuHhX53eoSPkXdl",
    "g5iDdouDYnumjGl0gHyQlm9th4N0mZpYXp2UboqOXWmql2B9kmByto1Ne5Vwg6dvVYuSb4+cXVOgoW54i2lsnJZxd3pwiKGAX3qLfoWVel98l4mCfXFyjJSD",
    "fXJzjJOBfnxuf52KbHeFgIeTeWqAkIqCfXR6jJOIcW6DjpCIdHB7jpaKbG+FiYeUf19ym5KCfXFukpaDfXtng6KObnZ3f5eQdXl4bpSwbVGYj2OgnlBtoIGI",
    "jmRylIKLiGV1hoyTd2OAjn6UfleGl3mNg1h9nn2FhVx5n4R8gWxvl5V0c39ygqV/VImPaJyZUW+kfnaca1yfkXKPc2GboGl1im+Gm3xxdH+UjXx0bYKiiGuD",
    "c3CqmFx7gnWelWp1doGlimJ/fX2jiGV9fIeffmt7fJOacG2IeIiic1yQjHidelWPlnWNe16RlnKJeWOWkXCMdGeekm98d3iUj3F2eYOWe3Z/ZoeucFqRfnKm",
    "hFCAlXONlFdlpItvhnZelKZncYljirFnXY17hZpwZ4N8i51gZZN+iY9mcYuKhnxze4WIj3FimJFsjoNclKNje5Nji6xfbp9vgallY6GDepBwcZOKg3xwgpOI",
    "fXpyhZiAe3pulJRzgH5umZdeg5dgjqJZepp3iYVhip94eIB4hY2QeV6GnH+FeFuTp2V6j1qHsGxph3aQlGd0f4CcfmaDdYepYVmhenqkXmGje3yVXW6nf3aA",
    "X42fa315aJ+KaIlrZ7OKT4t/brF9S5SKdp5sYZuCgZZbbqh9hZBHjrtbgJhQkLNfcJV3ipNtdIebh2OFiHGmjz+LsVyMpj+JxUt6tEyFx05ctn93nWljopxw",
    "bYp/dKmHPZmuTZOnMo7VQmC7V3zCTFmsenuWXnCag4J4aYWShnBni496h2tkqItck3RWu5c1kJhTrZUwkrBeh4xSkKlldoRqnJhfdIKIlXxrc5KVdHR/d5Gb",
    "YWmdfIiRUXqveHOKZoCvcGWQdY+dW3Geg3iHbnGoh2OAhH+SimJ2nYZ8d22RlHN0gX2Mk2pnkY2Ge2SCm390hm18sHJXnIF7nWRmp4htjHBzrIFahY1+h4df",
    "eK18ZYRyi51mcIp4kY9cdKJ7fYlVlatTgJFcnZxLfZ1wiolZgqh4YoyGdZ53VpmYaoh/XZ6bYHeAiJR5cHmIlntsc5OQboV1cK56VJ1/bq9uTLaPWKdtVMuB",
    "SKN/a6+ATJidaJmAS6qmT4qKW7OPRZmKba5wTKuUX5t3ULyVQJmLX6+BSJqVbo5vZqqHXYh8eKRtXpmBg4xZgadxdIhjkqtXa59yjpNKg6lvhn1aoJlhgXZ5",
    "qHlcjYKAmmJhqYJwkV16t2hqj2iZmlGAlXCagUqYo2KLemCuilmOdX20aVSkiXmWYHSvd3qSVpS2UHqbX6SgPouoaJeDT6OfYop+a6mMWoSIi5ZjcZmFhH5r",
    "hZaDe3R6l49qeIeHlXhjjJd9gXVym411e2+PoWdyjXeXi12Bln+Fd2qSlndzcoqVe3VvgaF5ZoZ5hZxrYY6Kintchpt6fm1qn4psfmmEp2xjiXmLlV1rk4KE",
    "eGCHk3x5Znqde3N7Z5SdX3eEcaKDTYmPepRkZaJ7fo9TgaxteX5loY9hgHaEnGpuhniYhliEjIOTa2uVhYh+YIqSeYducJ+GcX1xjZxyc319nIdseHqUk294",
    "eoCggGOHg4eYaW+RgpB/XYyQfpFpaJ+If4JfiZ93gG9woYN1hGGIqm5ufneciml7b46lYm+LapmcUXaXgo52aIeKjn1hhIyAlmVho4R2kFx4qXl4fmWWmG58",
    "bXmofGyCbI+ea3d7daCJZ3d3j5hxc3GCoXttgGuYolt5iGmmlVKAiH6eeWaBgpaMYnyKg5l4YY6NgJNsZpeUfXlyfJGRgmt6joOOfWeKh3+SbXOTdI+UXISI",
    "bKuBUZpzb8JlV6Zfi79DcKlXn6g8iphas4o1no5euXk6o49irXdAnJxknHlImp5jlXhJpphjlXJSro9njmtooY5yd3t3hpt5bIl4fKJ8aYt4dqqCYX6BgZeK",
    "aG+MkIqFcGiOnYZ4c3eIm5BsenaEqItmfYJ5oJdlcoeDk5tvZoiQj493aoWWjoh1bIebjXx5b4qYhYxzZZWTfZl7YImKgKF5Z4V6kKFtdIJvlp5yd3N9l4uA",
    "e2eAnoWAeGuJjoWKa2+Jg4uQcmh/iYuQdGx4iYuNfmtvi4mMhGpviYWPh2dwhoaRiWhvgpCLgn9yeIqDkIxrc4l+kZVucIOCk5J1cXeJj4aEdnKHhYiLe319",
    "c4+XfYJ5bZWSfY51aIyViol4b4GQkYZ+d3CMl36Hf2OIj36Yfl+Gg4OhfmiAeYChiWx8c3mYlHx1dXiJlI13cnCClIx/em9zioyPf212dYeUiHV0bX+Uin1v",
    "cHuHkIZtc3h6kIh2gnVqiYeAjHJofX6LjnFvfXeAlH5xgXpwh4d+h3NqgoGHk3VuenuMi36Bb3CSgH2RdG6HfoOQf3d+eYCShXt+dX6Kg4CAfYKFeX2KiIR/",
    "dHmEjJN9Z32DgZmKaH18dZiPdIB2couKi4Fre4N+joVyfXx9iIB/fXiHfHeNfHSPfW2JgHKJiHR5gXp/h312fnh8hH9/gnB6inJ9kXV2gnZ9hICBd3Z5eISL",
    "fXd2dYOCgolvcIl1fZV3cIl4dIaBgYV5eXp7iIWAhnVvh4iAh4N1eoF/iI5/eX14h5J+fn9xho56fIF/gYOIfG6Kj3eFi3F8j36Ci3x8gICJgIKLfH2EfoSI",
    "hYl5dImFgYyCdX2FhIGEh318hn56iIN5hYR4eoODg4eEd3eBhImEe3t7f4Z/fYV7eoSAf4J8gX9+iHpzhYWAhYF4d4SKfoGIeXiMhHqJhHqDgoGHe32JgISL",
    "eHmFh4aFiX91gYaDiYh6eYeEgIuIfICMg3yJhH6JhYGCfYSGf4qJfH+EhIGGiH1+iYV9gYCBhoSEgH2IhnmFjIGEhHd9h4eJhHt9gISIgX6HgnyFgHyEh4OC",
    "fXiAhH+FhXaAiHqAhXiAh3t9gHuFfHeIe3yLdHOJfH+Fd32AeYZ8c4WBeoR9doB+foF/fn97en6Af4F/eXyCfX2EfXuEgHuFgHeAhHqBinx8g3Z6jIR9gHqA",
    "hYGEfnuFgYKEeISJdn+MgYKDeHqHiYaCe3uFiYB9gYODhH58hISBg3t6hYd+e35+fIGIgn1+eX6DhIR9eXyChn51e4KAhIB6fnx8hHx8hn17fnd/g3WAhnd9",
    "gXiAhHt7gn98hX5yf4J5hIJ5gHt8gn6Cf3eEhHmBfHKFh3qBfX2GfXuDgIKDf355gol4e4Z4g41ze4p4gId6g4V/g318hH+CgYCHf3uFfYCLf36Eg4V/fYJ+",
    "hYmAf4F/g4KAgYKGg3+GgYGHeYCMfYSHdX6LgYSEeYGJg4F+fISDgIJ/eIKFfYSEf398goJ8g4J1goZ8fXx+gnuBgnuAgXt8fYWDen94e4t/d3x6g4SAfXd9",
    "hn6AhH19f3t/g3+BenqEg39+e3+DgYJ+eIGBf4F/fX6CgX6BhX9/g39/g3+Cg3uDgXuHg3qFgn+Gf4CDfYKEfoGBf4SCgICBgoGBgoGDgoGAgIOAf4R9fIKA",
    "gYJ/f32Ag4KAfn2Ag4J8f317goB9gn56f4B+g394f4J+g3x2f3+EgHaAgnyCd3eHhH5/dXuHhH16fn2Dg3h8gISBe4CBf4R7eYaAgYN5f4d8fYd/e4eDd4WH",
    "fYCFfH6LfH+HfYV/gYd8f4iAfomDfX+HhXqHhniCkHl7joF+god6hY58e3yOgXyMf3WIkHV/i4J8go19epSBbYyNfXuOfniUe4J5io9zh4OFdY+FZ5Z+fYKC",
    "h2+Re3yJe41riIh5iXaGcYqPaY58foZ2hXOShG2JdYh7g4lhk4B9fXOYZoiMa4J6lXB3k26Fe4SFaJd7bYt2jHF9lV2NgneOZZZwdJRtmWeEkFiidX+OZ5Vu",
    "iYpxmGCRj2egaoaLbZlsi4NzmmSQiG6XaYiHdphshoNvm3J7knKGg3mHgoN9eIOChId1goN7i3x4hn9+eIKJd4aBb497fI1liodxkGyCh3KTaH2Na5Zwb5Nw",
    "kHVulGaPhGaUZoqMW5hzeY5pjHt1j3d8fnuIe3mGd4Z6eY11goJ4iHKGjWuDjHSHfYCKbYmNbo16fIp1kH9xjXqIhHiFe42AfI5whZB6h3aDk22LjWyRhH6G",
    "dpKDd4l9g4p+gIF+ioGFgHqKf412gZJtiYl4inKOiGqYe3WScox+d5BziHx9hXyEfoB9d4iDd32Be4SAfoJwf4p7fn15f3l+hXp0hHx7gX2Fe3WGg3t+gHiD",
    "f4KDaomPcIV4go5sh4ZmloN0i2eKl2eEhHWHgX2Fd36FeYGEeIh1eI57gX90ioN4iXV8kXiBhHmLgH6GeIKLg3eFi3iJhn6JdoqObpF+fI1tko5qhoN/jnp/",
    "hHqDkHiAhX+If3yGi3J/iXmLgnOOd3+QeIJ7g410fod/hXh/g4J+hH50i4B7h3GCj3GBdYKKeXt+eYmAfX12iYJ8eICFeoZ9dIx8h31yk3dylnZ3jXaBgneJ",
    "hHZ/gYGAhn1/g3WJh3KJgXWLe3+MboeMcoaBdJGBdot9eY97fo51hId8h4V+goKAhYp+dYmGgIx5f4V+iIJ1hoN7h35+in52hoOAfYJ2gYWDhXJ6jX6CfnCL",
    "gH6HcYOEdoh7dYx2f4dyiYVxhId1iXp0hohxhX50k3l1kWt9l2yBgm+OhWuJenmOd3SIe36HfnWGgXeOeHCabnuZZoGYaH6Oao6MYY2OYZeFaZJ6bJx+cJBz",
    "eZJ5fJFte5V4fo1ogZ1jiY9jjoxnkn1smIBpkYdgnn9mnnBvp2l2oWWBk2yOj2GMlWaNiG+JiWuRhmqQgmyQimyTfG2Se3qTbnOYdniPeHWQdHaZbHmVb3uW",
    "a4CPa4KRboSBb5R+coh7cpB/cY91c5d1cpV1eJRweZhte5Voh5Fgj45kkodpj4RvlIFnlIdwiYJ2jXt1m3xrl4FumXF9mW57l3GBlmqBkneBkW6CkW+Hjm2G",
    "iniMfXOOiXSFgH2NeXqMfnaMgnmFhX6JeHuOgIJ6g3uKh3CIhHSTfXORdIOJe3qPenmVa4KPc4eHbI6Ic4SHd4SIb49/c4t9dYmEd4N/d4mIcYaEcpKAcJCA",
    "c5B3eJJzfpB2fYp2hoh6f4ODeYOBgn5+hH6HfH2KfHqOeYSFeIeEf32DgIKChXqLhHOPf3aOfXmQdnyVcXyRdn+NdYKOcoOKdn6Lf32CfIGKe3yIfnqMfnWQ",
    "eXSUc3+MdIKNeXyQcX+OfXyHc3uWdnqFeIGNeXeJg3WIgm+JfHmNe2qKiG+Ef3WIfm+KgW+Hf3OFfnOIenKEf3qCeneJgHKBgXmIhWyGgnSGgXaEhW+Ni2iE",
    "knGJfHGVgG+Kg3iCfIKLeneKhHx+hoF6iHeBknN4jnt+kXN9lHV9lHt8jnx6l3CBknOEh3iFjXd9iYh4hod1kHp3koB2i3p6kHaAjHd9jn9zjX91j3t7i3l7",
    "kHh8inx8inl6jHp7hnx3i3p8iXV6jH13iXp8g3x5jHZ3kXF+iHWAhXOGgneHgH2AgnqCgIGAg356hH2FgnqEf36IfIGDe4eDgYOAeYeEd4qEdYh/epGAfISA",
    "foeEd4uBdY99eZF4gI5zh4x3hoN4iop3hYd2hop4iYRyj4J2jXx9jnl/jXWChHaFh3mBhXeEgnqGhHaAhXeHf3eJfHSOe3iKdX+LdX6Mdn2McYCPc32JcYSG",
    "dYeDdYGFfIB+e4CCeIGFdYKAd4KCfnt7f398gXmAfniJe3iFe35+e4F+gXx9hH1+gHyAgHt/gnyCfnqCgH2BgnyBgn+Cf3uGg3yEgICCg36BgoF+hH5+inyB",
    "hXqDhH6FgH+HgICJfoKEeYqEfYZ/hIZ+hIF/gIKDfYCBhn99f4aDfYJ9goV6fYSAgH2Bg4B8fod6eYZ+foF8goJ7fIJ+gX53hYJ6f31+hHl+gX96f4J9gXx+",
    "iHx4gn+Ee3uEgH1/foKDfIB/gYF9gYSAfYCFgXiBhYN+foKFgIODfYSBf4aEe4OHfoKFeIOLeYGCgYZ/foaCfoR9goR4hIZ9f4OAg4F9gIOBfIKBgYF8gIWA",
    "e4N/fIN+g398gX+FfXp/gICBe36CfoF8foCAgX98fn+Bfnx+fYCAf359f4N9fIN/foF/foOAfH6AgYB+foB+f4OAe4GAfIF9fYN+fn5/hXmAgHuEf3+AfYKA",
    "fYN8fIF+gH9+f4F+fYCEfX2Ae4OBgIR4fYZ8gYN9foN+goF/gn5+gn6Bf3yCfn+Df3+Af4GDf4CFgHqChH6DgICDfX+EfoCAgoGCgn2Dgn+Gg3qCf4CGf3+E",
    "gIGCfoGBgn6Bf32Bfn+AfH+CgH98f4J/f39/fX2CfXuBgHyCf36BfoCAfX6Cfn99fYF+fYB/fYB+f4J+gIB/gIB9gIB+gICBgYKBgoKAgIWCf4GBg4GDgoKA",
    "gYaBgIZ9goh/hIJ8iYN+hYJ/g4SAg4R9gIN/hYV7hIB9h4J6gH+BgX1/f4J8foR+gYN8gn99g4CAfn+AfYKDgIKCfISEfYOAf4KBgYB+fYOBfn+Bf4CBf4GA",
    "f4KAe4GAf4B8gH+AgH9/gX9/gIF+foGAfoF/f4J8f4N8gX9/gX+CgXyBgX+BfIF/f4J/fYGBf4B/gICEf3yDf3yFgXyCf4GEfICFfICHfIGFgX+AgYGCgICD",
    "gICFgIGDf4CFgoWBf4WCf4GEgX+Dg4KCgYCFgYGEfoKDgISBgoN+hIJ/hICDgYSCf4GBgYGAgYKBgoF/goOAf4J/gn2AgnuAgX+Bfn2Bfn+Bfn+AgH6CfoB9",
    "gX1/gX5/gXyAgn2BfoGEgH6Cf36CfIN/foCCf4B+gYJ7goN/gIB+f4OAf4GAgICChHyAg4CCfIKEfnyCf4F/gYJ/gIKAf4GAgoN/gIN/goF9hYGAhH2AhH2D",
    "g32FgX+Ffn2DgHyAg3yCgnmCgX+AfYCAfYF9fn58f4B8gX5+fX9/e39/e32BfoB8f39+fX2AfXx/gX59gH1+fX59f358gH96gX96gn58foJ/f3t/gX1+g359",
    "f3+AfX9+foJ9f4OBe4GAgH6AfX5/gX99f4GAfn6Bfn9/gX9/gYJ9gYB/fn+Ag4J9f4R/foB+gYF+gX2Agn+BgX9/f4F/fIGBf3x/gYB7foGAfX5/gX19goF+",
    "fYF/fX6AgH59f3+CgX19gH9/f32BfnuBgH97foN+fYGAgX+AgX5+foCAf36Afn+CgH5/gIJ/fYKCfn+Gfn2BgYJ9foWBf4KBgISAgYSAf4OCgYOBg4GEgIGD",
    "gYSEgYOEgYGDg4SBhYV/goSChIGChoaAf4iBgYOAhYSChICDgYCFgX6ChIGCfoGCf4N/gYR/gYCBgIKAgX+Bf4GBfH+Agn99gH6AfX2Ef3yAgIN/e4CAe4B/",
    "foB7gH9/f3yBf4GAfIGBfX5/gIB/f4F/fICAgHyBf32Af4CAfX+Af35/f3yAg35+fn2CgX6DgH6DgICAfX+Df36Dgn9/gIKBgIB/gIGCgX9/gYKBfoGCgIGA",
    "gX+BgH+BgICCg4B/gYOAgoGCgoCCgYGAg4B/g4CEgX+EgH+DgIKCgIOBf4CCgX+AgoGAgICCf4R/gYJ/gYOBf4B/goJ+gIGBgYCBg4B/gYN+f4J/f36AgoB/",
    "gIGBgIGBgIKBgoCAgIOAfoF+gIOBgICBgoSAgYOBgYKCg4CChIGDgISEgYSDgIOBg4KBf4OFf4GFgYKEhIGAg4GFfoWEfIaAgYN+g4V/goaAgYaBg4KBgoOC",
    "g4N9gIOBgIODgYN/goGBgoCAgYF/gH+AgYB+hIF/gYGCf3+DgH+AgIB/f36BgH5/g31/gX6Af3+Bf3yAfn2Be3+DfYGAf4CAfIGCfICAfX5/gICAf4GBf4F+",
    "gYOAgYJ/gICAgH+Bf39/foCAfoB/f4J9f397f4B9gH9+gX2BgnyAgH5/fX9/fX6Afn19fn5+f39/f31+gn18g399fn6AfX9/fn59f39+fH2AfX5+e35+e35+",
    "e35/fH5+fn59fn19fH58fX19f31/fn2BfXx/gH1+fn5+fX5/gH1/f31/fn5+gIB+f4B+gX1+f35/foB/fn2Bf35/gH+BfX+Bfn6AfoF+f4CBf36Bgn9+gYKA",
    "gIF/gn5/gYCAgYGCgIGCgoJ/goKBgIGAgICAgYCAgX+Cg4CDgYGDgn+Dgn+BhIGBgIGEgIKCgoKCg4GAgYGBgn+AgYCAgH9+gX+BfoKCfoF/foCAfYF/foGA",
    "fX+Afn9/gH9/f39+fn9+fX+AfYJ/fICAf3+Afn9/f4J/foOAfoGAgYF/gYN+gYF+goJ+goJ/hH9/hX+BhX6Cg32DhIKBg4GBgYCDgoCCgoKDgYKCgoGBgX+C",
    "goGAgIGCgoCCgYCAgYCAgIF/foCAf4F/fn6Af3+Af39+f4B/fYB9gIF/foCAfH9/fYF9f4B7f4B9f31/gn9/gH6Bgn2AgICAfoJ/fYV+f4J/g4F/gYGBgoB/",
    "gYGAgIKAgoF/gYB+hIB/g3+CgH+BgYGBgIGAgYGBgICCgoGBgICAg4CEgoGDgIKBg4GAhIKBg4KFgYCCgYKBgYOCgIKDgIGDgYWBgoWBg4GDgoGCgYOAgYGA",
    "hIGCgn+DgIGCf4R+gIF/g3+CgICCfoGCfoOAgoCAgX6AfYGBfX99goF9f36AgX+BfYOAfYB/gX1+f31/fH59gH99gnt+fH2Ce3yBf319f4F/fX+EfIGAe4V9",
    "fYN7gnx/hHuBgH+DfoCDfoKAgIF/gYGAf36Cf3+BfYKAfoOAf4OAgoJ/gn+BgX6Cf36Cgn6BgIF+gH2Bf36Af4F9gX9/gH9+gn6Bf3yCfH6Afn19gH5/gH6B",
    "gH5/gH1/gH5+fn9+gHx+gXx+fn5+fX59fX99fX5/e4J/eoJ9f4J8gX+BgHyBgX2Cf36CgX+EgX+EgIKAgYKDfIWCgoF+g4GAgoV+hIKCgoOBgoSDgYKBgYJ/",
    "hn+GgYOEgIWBhYN+hYWAgoGChYCAhYOCg36GgYODf4V+g4GAhIOAgoSBgoKAhoCAhn2Cg4CDgIGBgYF+g4CCgICCf4R/f4OAg4F/g32BgX6AgH+Bf32DfoKD",
    "fYN9gISAf4GAgYF+f4R9gIF7gX6Cf3yEfn+Ce4N8foF/gYF8gIF9hIB/gIB/gIB+gH+Bf4J+gn+Bf3+BfYGAgYCAgIJ9goF+gn+Dfn9+gX99gn+AgX6Bf36B",
    "f4CBf4F+f4F+gIGAgX9/gYCAf3+BgIGAf4CAgHyDgICCf4GCf4F+gIB9gnuBf36AfH1/gH2Af36Af36CfIF/fYF+f4B/f4B9gH59fX5+fX98gH99f35/fn59",
    "f31/fX+AfoF+fn+Afn+AfYB/fX9/fYJ9gn99goB/foB+gX5+foF+gH5/gn6AfoCAf4B/gICAgH2AgH5/f4CBfX+BfYB+f4F9gH9/foF/gn9+gn2Cf4F/f4CB",
    "gH2CfIN9f4N9gH1+fYJ7gX98f36AfX99f319fn17gHuAfX5/fIB9gXt/fX1+fX97gHuAfXx/f3x+gX1/foB+f35/fX1/fn9+gX6Ae4N/foB+g3+CfIR+f4F9",
    "g4B/gYCAgoGBgoOAgYOBgoGCgYOAgoN/gYOBgYGBhH+CgoKCg4KEg4GEgYSAgoKCgYOBgYV/g4GCgoOAg4OCg4KCgIOBhH+EgYOBgIWAg3+CgYOAg4GDgoGF",
    "f4aBhICCgYGDgYGCgYCEfoOAgYGCgIGCf4GBhICCgYN/gYKCgIKDf4R/g4CCgoOBgoKCgIKDfYV/g36DgYGDf4SAhH+DgISBgoCBgYGEfoV+goCCgYKDgIOA",
    "goOEgISAg4GAg4KCgIOAhIGDgoKCgYGCg36EgIKAgYCAgYCCf4GBgH+Bf4CBgH+Af36BfYB+gH1/fn6AfYB9f3t+fX1+fn99f32Afn9+f39/f39+fn5+f31/",
    "fn9+fn1/f36Afn98gH1/fn5+f35+gH5/foB+f36Af31/fX9+fn6BfYB9f399gH5/fn59gH1+f319f4B+gH6Af4B/gICAf4CAfYB+gH+Af4CAf39/gX+BgICB",
    "gICBgIGBgICAgIGBgYCAgYKCgICCgYGBgoGBgYCBf4GBgYCBgICBgYGAgoGAgoKAgoKAg4GBgoGCgICAgIGBf4KCf4GBf3+BgX5+f35+gH5/gX9+goCAgYF/",
    "f4KAgIGAf4KAf4KAf4KBgYGCgYCDgH+AhH+AgoB/goKAg4KBgYODgYKCgIOCf4KBgH+BgYB/gYCBgIGCf4F/gn6AgICAgH9/gX6AfoCAf36BfYCAfX9+fn1+",
    "fX59f399f31/gH5+f35+fn5+fn9+fX1/fH1+e318fn98fX59f3x8gHx8fnt+fXyBfX99fn98fX1/fH5+fX58fn58f319fHx+fn9+gH2Afn6AfX+CfoB/f4B+",
    "gYF/gIB/gX9/gIB/foKBf4CAgoB/gX+BgIGBgIB/f4CBf4SAgYJ/g39/gX5+gn+AgICBgIKBgIOCgIN/gIF/gn+BgoGBg4GBgYCCgYF/gYJ+g4V/gIKBgYOB",
    "gIODf4CDgIGAgoF+hYF/hICCgoGDfoKCfYSBfoGAgIF/goGAg4GCgoGDgYCDf4GAfoJ/gYGBgn+AgoCBgYCBgIGAfoF/fYJ/f4F+gYGBgoCCgX+Ef36CgH6B",
    "fn+CgICAgIGAgoN/goGAgX+Cf3+BgH+Agn+Bg4KBgISBgYSBgoCBgICBf3+Bgn+Cg4CCgYKBgIKBf4KAf4GBf4CAfn6BgX+Bf4CAfoN/fIF+fn+Af3+Af39+",
    "gH6Bf36DfYCBfoCAgIGAgIF+gYB/gn9/gX+CgH+CfoKBgIKCgIKAgoKAhICAg3+BgoGDgYGDgYCEgYKDgYOAg4N/g4OAhIKBgoCBgICDgH+Ef4GDgIKCf4GB",
    "gYKAgoCCgX6Bgn6BgICCfoODfoKAgYOAg4F9g4CBgX+Cf32CgH+Df4GCgIGAg4F+g4F+goB+f4F/gICBgYCCf4KBfoGAgIF/f4B+gICAgoGBgIKBgIOAf4F+",
    "f4N+gIJ/gIGAgn6Bgn2CgH+BfX+BfX9/fYB/f4B+gH99gn59gn59gX9/fn5/f32AgH+Bfn6Bf32AgX2AgYF/foJ/foCBf4GAf4B+gH9+gH9/gX9/gYCAf4F/",
    "f4GAf4B+gH99gX9/gX19gX5+gIGAf4GAfn+Bfn9+fn5+f39/foB/fn5+fX58fn9+fH59fX19fXx+fXx8f35+fn1+fn59fn1+fn9/fX2Afn1/fn5+f35+fn9+",
    "fYB/gH9/f399gH9/gX9/gYB9goF/gYOAgIKAgYGBf4F/gX+BgX6AgH+Agn+AgYCAgYKAgYB/f4B/gX+AgIGCgIKAgIB+goF/goGBgX2Agn6Agn+Ag36BgH6C",
    "f4CDf4CAf4OAgYKAgYCAgoCBgoB/gH9/f3+AgICAgYCAgICAf4B+f3+Af39+fn9/f4CBgICAf4GBf4KAfoF/f4GAf4CBgIKCgIGBgIGBgYCBgIGAgIGBgoGD",
    "gYGDgoKBgISBgYOAg4KChYKCg4GChIGChYKChIKBgoOCgoKBhIKChoKBhIKEg4GEgoKEgoKCgoKDgoGCg3+Eg4KEgoOBgIKBgIJ/gYJ/goJ/gYKAgYCCgH6A",
    "f3+Bf3+AfX9/fYB/fn5+f31/f35+fYB+fX9+fYB9f4B/gH9/f35+f35/f35/gH2BgH2CgICCf4GBf3+Bfn+AgX6AgH+AgH+AgYCBgH+AgICAgH6Af36Af4CA",
    "f4B/f4F+f3+Agn6BgH2BgH+BfoGCf4KBgICAfn6Af35+gH9+f35/f3+BgH9+gX9/gH9/f39/f4B/gYB/gn+BgH6AgX+BgH+AgH5/gH+CgH6Af4GAfn9/f39+",
    "f399f4B9gH5+f3x/gH59fX59fn59f35+f359f399f39+gIB+gH+Afn6Af36Afn6Bf32Af35/gX9+gX9/gH99gICAf3+BfoGBgIGBgYGAgoGBgYGBg4SBgoKC",
    "goKCgoKCgYKAgYGAgoKCgYGBgoGBgoGBgoODgoKBgYOAgYKBgoCAgH+Bfn+Cfn+Bf3+BgH+AgH9/gX5/gX9+gIB+foF+fYJ+foGAfoCBfn6Df36Fgn6Dg35/",
    "g4B+hYF+g4N+goR+gYSAgIWBf4WEgYWFf4OFgIGFgYGEgn+ChH+ChoCAhIB/hYF+hIJ+g4V/goV+gYWBf4WDfoODfYKEf4GFgYCFgX+EgoCFgX+DgX6Cg4CB",
    "hICAhoF/g4J+hIN9gYJ+gIN+foE="
}

local EMBEDDED_SCREAM_U8_B64 = {
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA",
    "gICAgICAgICAgICAgICAgH+AgIGBgX+ChYF+fn6BgXt6gYeCdnyFf4WFdn+Nk31re4WOinB0jZF+cHh9eHl8fX+GkYyAfYGEeHqMjoF7gIB9fnZscnt7iIZ6",
    "iKGXbGh4foaehW+IoH1bdYNzaXaEkIaHmZN3dnpvcY2gloSKimxfd3pha4OgiHGQrYhcb3Vvhaihho6YelZfcWBhhamNd5GtkVpcanCHpaaVk5iJY1NVWmiS",
    "p4mBnLSYSUJhe5qUkpunnYZfRU9ZfqWVe4q5uXI0TWuRm4aOoq+PbVlDTW2koH97rMOROzRjkJl/hJ+zn29WRERonqiPgabFlz8sVomjjYSitZlxWTw8ZaOh",
    "loqgtqRHIFGDqYqFoaKXfU01Q3Gwo5aKn7qUNSpYj6eKiaGgnYQ/M06Tro2RjKrAiyoucaiQb4mvpp12NTFgrJuHk5WyumUhR5umcmyXsqSWbFZETp+gi6CX",
    "p8JxHkyOqoGBo6ORjFwzRI2we4mhq6uvUx1OqppWcpSfn4pWO0SMspmai5G5micxdqqhhoeMh5ZbL0SD0aN4dqKrnWMsSZi9bFuHrqODZkxFeL+fnZWGoZhF",
    "L26ztY97ioOOXClIf86ual+muI9TM0qJwWxolrCmc2A8SZjGmIqNjaaAKzyJyLVxYX6PlEw2SYvgtHNIkMOgUCdWtdZ3P3KssGcqRXrY1mxWh5CrVC9Xsuuk",
    "Ylp4l4w6PG/V5Ik/VZWvZTFYueOiTkx1pag7Ol7D9Z9HQ4WrejxFo/OyXESGoYpEN2PH6aJJO3esmUM4k+2uVz11pKFhN1W97K5cKWOfr2QyiOK7bzhbqqVS",
    "N1nB7qpRLmmNmXxHkOShZT1knpVqOGPQ4a5PK2acjlpSo+2vZy5ctJxTOVfM9apHI2CToWdAne2xXzFVuK07OXTe5pY8Nm+xmkxChuG1fk5yvo9HNljN6qxP",
    "IWm1qkg0o96saDJfwLQ7MHPP2ak3NoubellirsGJcVGIzXUvQ5XrxWQwWZ2sXUB45KpkXlGl12MhW9XppD4hXpS+VTCg3qJkPU+ux0Ysdt7jhzE3abysSEes",
    "1pNbOIvNmUAtn+rIdhdOg6F/QnvSt3k9PorVfB5ex9vMUxdVlZljWZLnlFpCUMSsPT6L3+KQNEZcsJlIa7a+kl48fMWHLVezz9FkJFVmrXxnorqaZkRTm8Nx",
    "Km7F17hANm65kEBMt9eRdxtow71TI3jZ56IoKXaTmVBQ0c2PPClj06wjSpLQ6YIlToG2omlXqKNuXFGjvXs6S6nsx14xWn6xbEjJuY5hIluNxGYyodTRlSY2",
    "c6m1e3CwgllVPp3djD4xlOTNkCFPbZqoRXzOp3YzPoW0bS6Ez9LERSJZmLCfbn+4ZF1DfciicSF80MOuKjt5sa0+Zr6bhFtCj7ZxLVe+3cxxJUZxoZh3pLRP",
    "YEhdysZpH23GyZc+Upa2dDtQ0tFqV0STv409Mpj7yZEeJoO5q0prwJdUK0im3HIxTpPqwlkrXKrEjihs3K11O2Wiq3Ypbtnpri4lU7HZjWiIjklEVJDltjYo",
    "adLmhjE/d6KjUHDSnnpGT4y8hilg2Oq8RxZUbOGXUbSeY0BRjua6Pidhz+aqNDBmrLE5VNC4lVEohrKwSDeF2+VqIj6l4Y5DLJXfhEdmn7aMRjV168uQMCqS",
    "05hCSoerZmKBsLZCMVCO9rtBUGmiyGszXsWYinBwuItbTleg7YFcTGmxuGpbfoiWYGun13UrQG/L1Ys2VJGlgm9Ub653YY27iGQ7RqTitVc3W5nCejN/ho+y",
    "dZWkcjg8cMHqozk0e8qoWD9fvKl6eKqcdVU2Xs3dpGYkY5qgi2J5mnploKiEYGZ1VX26k6l2TceQNj9+tNCoW1RJbrbgVSJkerzQX3ergzdHirjafl9xdHta",
    "XG7GvJhpRl6vpCtBitPSgDVZgapcNXK+25NLRXK4jDhjrM63Y1Bff3tnUXz0rnJ3Y0eUeUu+u6J8Wl+BtGw+Qq7YrXFIWnuca3iUs6RrUYqPazdLksnphT9Q",
    "VYaZepnQnHFBVoaZq0paa7XTm0JQqqNaPIq53J5IWV1iY699R9yUeolJiM5yKWmewsRgUHlcbYRiedeqhWI/XLLkUDOIW7nEVG+AV2WjWqzMgJF7VnbAZGCS",
    "Z6urcVtsWWeNa72+hlpadWnFkFaZcoaoWF19XG9+iOG1YVBacK7XZk+CeaeEX2VhsaNwMHa5qZdLi32cTWOxn8VTO0iH0E9hoWnLkThrjKLSmSdpeXeyfZqW",
    "XjJnfqflhXxWUJaKSbudoqg8MliDrtdPUJSImm1gi7yuZUJfqJGdi2R1jUxCfMXYmkg+XJ/dXm6PRpuGV3iMwayJMEivkpWGcaqORT5+tMSGQUFepsuwLDea",
    "faWeX2zRkyZMlJOtmUiIfn9sjHKSrnyAXX2jwUctiYe7o1Y/crGUsU8rpImBsmmPok8/ca+6oGFqe356VX6fvYVRYn6jsaVANYaLm796h4BeRWhtt+OLVzyT",
    "qGtTacDQgVdUcXiUyWw9gpCTdGe7s4hWNl7Jtot5cnpfdWZyl6uDkWdMga6WMlSfw8JYU2hxkLWTKWeomqZ2a4CeVUKW2M53QEZgmKmta0uSbYGJZ3PKrjVA",
    "g7vJf1Jia5aIgT+AtJKTanl6iGI6r9+xdCtBacGqnVE1knqLlHt2qqM8R6jKoGlfbGiZoXBDgKCImV9yk614MJXMqntEUH60kYhLQKyKjohtcamkPmS3x5dH",
    "RXGKtJpcM3qaiaZxXYzNhy1/tZ9/XnR/noByQ1KyoZ13VG+ssk1ir55+amdhkaKGYTmDoZGSZHqlsWpAlq6Ue09knaCIaS5wro2ia2KKvKs/RaC1j2Rrj41t",
    "WGhOpKyIjmNzjNFmMpykn39baoCYjpFAQ5KMtqJ4cpeTQ1ituaRmTl10rZFiMn6fkbVweYqmlidqr62UaGppjHd/WmCofaqXbmyXtUhIm7O2Yz9qcZW0jT9F",
    "g5W6q3Jrh6E+bq2wmFRYZZOJll49m4abwWxWgsmISGCDt5Zjal15qpBbRY2IrbFsZXa3R2Wsl65mRFWJrrhuK3Cdo69gfJKkmDBVpLeLW2djd5uBW2evhpqN",
    "Wm6uyUdCfJG9gUBkfaSpjlpMaZizvnNKo6o5cb6UfDZPlMmij3EpTZSfxaxYZ5B+coJ/iG1zXmq7u3ZuPkmdocWtcmOFXjSdwJCGWEhoqLbFhiE/cL6ysXts",
    "hVE/lcSYcUZeZ7vKj1IrarK/hGiOqHs0SonQj2FgRIPOsZlZLFOmyaV6Xo6KQEqzvINUTWioyZWEOziAv5uUn3CBXTZtvqdhflxNo9KTllopY7O8nZtMZoo9",
    "ZcqjfHFLW5q7rqE1MHnCpH2Mh5RnOVepr3CCYFK1uIqFPz+H1KV/Xmmgikp+tphySFWX0KOPZTNJnb+XpFpkpXBWeJiFgXZeir6cfodBN4epp8JlU4tyUJCw",
    "fJJhQJLLl6F/KEOXrKe1VliSf1V0k4OVd1Z8s6eVfTRBiKqtqGV2jGpLdbCejWBNhLiZkX49TYairKRtdI92V3CgkYdtWoKqnop3Q1GNo6GVcn+SakxtnJCK",
    "clKBsZWQgzo6jLKwrWRee31YhqVzgVhenrCanGUiXayrropbfZdgT4ehg4ZhVpu2lZGGOj+GsLOqbGWCbk2huotwQmWXtKKkaipZop6oq29qiGdcjKJ2bnRh",
    "jbyginU5Ro61taBfbYpwUpaYeIxQYobBnKR9JVObrJ65ZFeKeFmIqW94dFuKwqyObjFLlLewn2dbhHVTk6l4cV1WidCfjnsuRYG5uLtgQHCWcYefaXdkb5bB",
    "nYx8MkB8vbK4ZkJuj2iAqXV4dmF9s6t5kFEyb6vKsHg4YKZoXqiWdnNYa7PGjJFNL16xxKh8TnulZE+FjX9ybmy7u3F/UDhhycijbjByv4ZVf3lyf2aVxJdi",
    "gHQ9Vqu7s5o4YqqCUH+IZZyKgJaHcJyWL0uLpsuZVV2TeE1/koSZemCGpIycljs1Z7PJsWxUbXFrf42RiWZzdZiSnJM0QIWmqr92SJB6T3OaiXyXY4Wseoex",
    "Zj1QnrKxnVCEWWJ9mqmHfV9mhY6iqEtNiYyNoXuAwHIwR2yiqrtXTo58r7CbTCx0l6GjmplQNGqbtbhTPG6DjL+gTlRymZOEepnEhDozVI+ruIRNe5Oem6Nv",
    "LFaUkKm0k1cxYom5wGcxZoqEua1SUoOMfn+msrNoMklRj7m7oUNSeaa3r5FKMU13n9vHZyZGfbTBpWNCYWWvv3RvZZF4V6PCjX5hQ2dzkamvgFODjKGrlF87",
    "TG7H261FJlCe2J+TYDtVc6bYmkNVcIKMk5+5lTREVXG8vqZpR2OIvMOIYjdDeZy7xYUqQn2wwZNPSXWBkMKCX2Vhpo2BeZGcelRZaZCskHxZfrCrjotIK2aL",
    "nsCiaTZKgL3Ol04rYXyz4aA/OWaGtI+Rpo5cRVhsuK+acEB1rbGyhDM2a4+fu519QT+JubyMQU5ujaHIqjo8W5m8mY6EjXtJSG27tJp1N1SC4cqLSShPkLKn",
    "n3lSYG96trNiP1qFnsyyTipYkbetbnSYgmBsc6ihgmZJdMDZnGI4OXmsnaSJfmFUZ5q+oV1MXnqgvbZnMVKBnY6YnZyGQERhvLWZgURdhsi2mlkoT4qioqqV",
    "T0hsiq/DYTpij5esuFktXnaptm51mahYUFCewplxQGqm0aV7WC9SnpuhloV9VVyAl758Rll6rKerYERZd56YlYeEs3A9RnnApJxWbHiRsX+cUi90nJynm3BX",
    "c32Xr5VRTHOdmLh5OVRnl7OlY3mqgltXaqSukmJLa7rJj4hKL1eeh6+yf1ZSaZfAqHE1X4uTupdCT2OSraaVUWiek3dLcIiau2pnTZ3ToX5DOWCroKqfXFd6",
    "e5O7olE7XH3G33knP2uO2Z07d7yeX1tkmLGZbE5nvtR/VUA/lLmTl352kGJAlMCZY0hQrcOtnTUpZay9l2lZfaZZW3mgmoxiUnPIvIB9Mzh5q6m+b2t+X0mT",
    "wrB1PUtyxLXJcBo+e6a5p1llcn95eqKbel1JbL/TpoYuMFCZscafXlpQaHjEq4hQRGaqzsGOJjNprLamcU+VglVwnJZ8iUVupNWvf2AyRIO/t7pxYkREj77B",
    "kTs0Z7jHvnMnOGaex7BwVHWYY2qHoZF8UFOSz8aMZjk3Z6+7to5hRFNxo8WzUCxPltfJkygxXYbGwX5qbYltZH6fiX95V3Kvy5B6QjhVnbiwrmRVQ3WhtLZa",
    "N02Vy8OoPClQf7PNlGRpiHdhg3qSho1ZZJq+rXVYLk6StLmicFRUf3qqt189WH7H2qU+JVF8w8xvVnuWhW9nfo6BkGlxp8qDZVo1abmmqZFmaWB2lLWXTkFh",
    "lNXGkzMrWpK+uIJbc5VwU3OXj5d9VIGhu49wSDR9vrSiamJpaXqmw343Rly04798IjVumc2jW1eApW1neo2Oi2Rnm8OheFE2Ub+ynY9RcnhnfLuoaEJcc8nE",
    "pWYjQnmtyqNZSYikYWGPlpCKTWuezK9+NypvwcCmbklZiG59sZBwVlNzysqpTCBKj9PBZUJio5pSb5STkF5bdtS8gGouSrO8jpdfbo1vVqGde2theK+8k4I8",
    "N3uvtJ11YH+JUm2klY2ITmaav6+VQyhbo8Wte1BtdlR+tJ5/WFxlk8nGcyI8acTOfVxXj4NVeKulhWRJa8DGoGMsTKDIkXxma6lsQ4+mjnFlW6DIrYguOny2",
    "t39sXKeDNHCmpZ9uQmC2vKWCMDiCu6WaaGOPa0+Eo6d7Wk6Au7y8TyJTi826cT51nGpZi6umfkpQfM3Fm08qVbq+lWtUfp1bUpqnmWRGa8LFp2UlSJLOqGdV",
    "cp5yWXuolpNXWHm9v5JtM0acxKCOYWqAYlyouolcVWCdwbuXMyxkoNGZX0B8n2Rml6GSe15pfKfFo0ArWrbKi2RZfI5Fdrm3fko7c8neojkoWZ/hoUBElL1e",
    "Wn+mrHtWXXXPwpBPKVm5voxpaHWQUF+6uoFNSHDPs6x6I0B0u9V+RU6SoV13qqGHWl6EqZSofi1UfsHDckp3p2ZDh8C2ZkdUgbzXqEcrTIrRwWE6ZZ9xeait",
    "iU5BarrDqVwuU3TCr1ZmfKmITW+VlJdtW2yhvalwQjdzvsBzSWyBjX+FqptPVV6xuKaGJkZ4ss2GRVOEn5lkhJB+a2WFhdGyclk8SKLOqnNCXm6MtcuXPkJR",
    "g9bRp0sfWoPCxWJgVYKbfISVfXd5a46RuatnNEGgt6dqRnicZXqyqoZQU1u+uZaQLVB/m7yZV1pxn4RNsqF+YU6BrcmkeEEuZr/LkUVGcoWGl6qjUUddhLm6",
    "j0BAbpXHoU5UZKmpTmibqZBaZH2ll5huU4GPn3BuaKiFWYSUoZhfUW+fnYSPWXiQk6JJUWurq099gqiMblF2q5+OT217qqN2ZlhimKSYkXR6XlZxkse9aSNU",
    "erPgdTxInpaCf5Wph3RfZ3Saw4FPdXyrllFZe8x8R3lyp554fIFudK+XYmiIp6NFQY7NdFJvkcaQUFmKioCsmll0c5upVTyFxY9wX2Cgk1iRoHxag4hso6OD",
    "ilg2d82hY2VWlaOPfYJaQI+ms6NldYhgYIqinHtbWoSSp42McFtMadjOl1A9XISzsJiAP0p6mrqlcmRKTJPMyIZVPmKmvl9binWTi310nn1ynFZTscW1XSZS",
    "nMOkfmNrWmx9ncOOPlFjdcXUtFAmR4zclnBbWXmGk4yfnHhiPlex3LpcNk51pZypnFtZWmGQwblkP1N2pL/Gkz07haR7eox6h2hxiqSFZolRbbjEk2NaWIyh",
    "fJWXZFlqa5O8f3BdRoGzp9B+KzlyzpiJeWZpYn+EsphjVlSKtca6WyZGjsWjlmtPd2lee7yucFpIhL64pm9SUpWfaKB/aI9vXW+ct5hbQIa3q7FlSVaMs3ma",
    "gnx3TVtsw7V0XkdtncPEe0VQhad1jY1lf3loYZivlnExZp/At2xoXXmOdZyfgndUSl+DysVmN1Nvodm2hF9eUkqZ0591TmFlf7Gwkz5GaaLYpHFcb4hliK+V",
    "bFZjdZSCkZ5nRmmRzsZfRmiWgH6NmINnc2V4paaVXUBmjsi/f1RemZNXd6WNfGhkaoePlpxOSo27zns4W6upaXGAioh7anaLfJSbZUNYqdSVUkmB3ndEe22d",
    "kltilrSFhGY7cbfSrURCd7ylXlyMkIF4WJKqc3FtWX2ruI5dUl+/uVRobm6Re4ODi4V0jGJYhMfFlEk/ZYmYnrKKZ1BNaMKtRFuLg56jhYV9bISrdXdsbY9z",
    "e5VwaHh8gJqsmIBjeHFXfbWyiWpdRmeXo8N7MkR9sLy1hl1bdJmNlZJscGlvhI2QkVlAgsG0m0pHk6eAcpZ7e3tiaoGGo8NOKm5+quCHZ3d7aV+YqK6GUVBi",
    "h4eimWFzdJ+iVleE0INPb16Rqm1seomMmo1GRni6zLVSL3OAgqmWoYY8TmatxoNPWmuRzaxnTkeSzot6XmaJiWx8mm52fF+UrqeKcHdocneVopR8Zk9Ub7fZ",
    "kUAue5a0uWtre4hrdaKjkWRbbXusglqBdpKtnn4+YZ66hVp0aJeXc3OHiouMZVVrp82ZbltBfKGUspJ4VzlifsLMkT83ZJHfsllFcLGPXG2NqZV0YWx8dYlz",
    "aq2wm3JQY2eumYR7ZY50ZVV/yblsMlaKo8ycZldpj3eJlZCXblhpjaBpc3d5preQP2Jwoq1wd155fIyUeIt2dmBUh7zJmVdIWnKkqayGYVJOe4y5s3g1R3uS",
    "5LFVT4CdZX+Jk6R+YGiWhVlkiJu7sYNVUXuGoIuPZ2F+bXOBuJyHUTR3waeZl1tydWRqp8eKVkNYf6i+glBPcZa2umplgodvYYihi3NadpCMhYeDRVmRvcSA",
    "a2hsbGukuJpjPE5ylrnKXCNcdrXkeFh+lXBUd526hGFkcoiJnnhHfKC3n0Vho5pcWXyeq2tOao6Rj5tbVY+RvJ5TZZKuWVuCiq90Q4Cii4KJZWB5p8+STkOP",
    "t2lniYqaZ1FyqIZgjGdkn7i/j1A6dbqNgWpziG1Xdq+MhG5Mdp2tu4JUWZmia4Nie5F6c3yUY3dsbLumq6FPUWWknZGMX4BuYniJlY+GRGO0m6+JWlt4p3Oc",
    "lnlsRXR/nqxyUkx+nL7Nf1pOWW+s0oNtXktzg6Sni0tHdYfWx4FbT216p6OMeWhmUWdttOKGM0hwqcGag45yUm9kkbyUWVx7cZKhcUp6sbGnXWGXqWpHdX6e",
    "h3mEb21/pJJ0YmiZr3d4oJN2WGF+sHxpcGaAjK+PVDyHt7ieZGKHoGRAbaeci3BugHNfepV1sr2HeVJcaa2rfX1mW2V8kKmKdHdrXoy1s6d6TF2Nd4KDi5Zg",
    "Y2R2iMKoRG+AjbiFa4eXgFRrhJeUanN8hVllko+up5R6cE9bnJKiiFBcaXaUtZRdXl9zrK2uhWRbc5SEoYhsaWxgaaaointnX5isrZNnV2uNdZKbiFtXZ4it",
    "gIJnXZeYoa+AXmKGbHuxcWh1bXiclm+PY1qdvKuOekBwimibqpBjXE5ms6GYkktMfam3s4ZIb3RZfp+nj3BKbH97lotnd6SpsoVAZIN0mIp2g3lsapCMjXVR",
    "caKzuI9aTHSZe4qIeGloaH6WiI5+XmiVsKyXc1BYY5i4mnVfW0iVq5aNXUtps8Orik5RgX2ZpohmWWhrmaeKdGNcjMasg3FsX3GTr5Z1WExdksKeeFJDe6q6",
    "voZgUWlyl66YflZiYXeNrKZVTXePtbGJaVtpapevpH1MT16hsYxZSneIxtGBS051dquueHxnYWuNm5x7R2BzpNSje09OYo7AnZJ3S0JchLPJn0YuV5rSxZZM",
    "R2x8epKroXpIU3ObpXVWb5+9tYBORXmmn5hwdW9pao2vhXxaV4G0vKhyUWhni5SkpHNjQVWRtqOVZz1oqqyvhVNndneIlJuKaV1jjYx9aVyLubyiYTpbeaPB",
    "q2RUUVl5oMKndDxDbrnLtYQ9VnqMkouklE1FUoG+vpQ7OXGxyap6Smt9Z3mdppJ0U2aBipN8W2qurq15Qm59hZ+LhHlhZVqbqYyRcklRrNCvZ1Fod5aXdYKJ",
    "Y21vj6iCZ19ThtnHn1wsUo+ZnauDVmBfd6aeglpab77OmXxOTHWTl7SFbmpLX46fnppvUWyXq7aKYWNlbZSqioVuU22Ni4lwYICitqiOX0VneIyanpZmYVZ9",
    "lY+NRVmw1qt8Sk6BfZ6+m3deR0h+urCUZ0BUj8O9l2NUXGiYrJ+PWDdhh6i0l2o0VKTBsodiZ3Z8cXWct4BRV1x6mcCfR1+NgpWUhaVtYG1ep6J0d32IeHN1",
    "dnGUw650VmBtjpqPbXp7YYOGnJNqXVqAtMyoc0pGZqK5nol6UUxogq+fjGRTa6jJqIU5UGmUuo+MaF1jbo6gjXhcaaC1rJltOFONl6OXcGRnaX+rnV1Kaoe8",
    "zZJdV15wl7Cga19xX3Kok3JhZoSqyqRsSD5clcrCjGE/Qmiju7GJOzdxrse3fklTbpGhmahuOkxrkb+3hVlAWpa6tY5pYVx9ioudlWdbcoGQfYaCao6kp5Jg",
    "Y4WKdHB8no56a2t/dISsmmtxe4KVi4t7c3xYeZSBiXeAgIF3WG+Is8ueWlBiao2emoNxa3d+jod2eGR0rb+eh1I/VYyxtZtrZFxWZI6rr51fQmiXu7SEUVVp",
    "kpN8jH99bnuLiXVecIm1r4t4XFRogpuehoBuXWqTj3l1XXixvZx8XUVZi6u3i25hVWCFnaygallhkLGnl31KVHaotohvXlFol6Chf15MbrTNpohXP1x5rrOV",
    "eWVLZYyhiXdvYZq6j4eRVFV0ipiikmVfWXiQppV4WF+kqqeOfVpXen2WmIx8a1Z7fXKfhnCDrJ2FcmNseJiOfIJtaW+FnXNuenx7lLudfF5dbpCrhnNycWZ8",
    "mZJ/UGeAg8HBnHdVSlSHrbGhdFNTYoaynGZQZ52/u4xdQ2CSmKyWdGdXYXOWnYCDfWyRnIaWiFVPd6ikkX9cUWiVl5x+S2GDr7SpfkNYeoWvo3V1a1Blkp+d",
    "c1lqkLOtgIBtP2CWq6mTdEhMb5C2q3Y3TYS2y6x8TU5ogpOpp4BUS2GHq6d6UWmTq5yUeGBpdICAm5t/YF50hZ+FemNopaqakXNZb4F/hoWJe3p0cYtvcIGb",
    "pISWbGGAgIONl3h6b2p6gpaHi2VMfqSamrJ8bXZjWm6srIFvcnSAkXt0bWaHurSddVBMa6KOj5uRdVdRYIOqmoWJcJCag4N6blxumpqSillQcISQtZuCaERv",
    "kq23Zl+HfHSBiZqJZVhmm6aNTVOhrKeXc3SCYEluh6e2f1ZYgYaDkYVpc6iZh5lySmSIjpi1f0pTV2yYvrOgcj1LeJu1woBJT192lryWeHZYZoB/haaOeHyG",
    "lpCJX0hgkKGXjW9zdHVxeYGfvXhsenh9iINjhqWHdnVwbYOIhZiUdW98dYCsool9SE5hhMSZioZeY3yGhI10a6GxmppiOVuFf5urpZFZR011mL22kmVDWZio",
    "q5pVVmZ+gJOpjYFtZ3SInYNdbIeeupNVTWFhfbublI1iY3J9eZKajYeEinx2g2RQdI6cpYxnYW1Zf8WuonQxQ32ttauDWE5jdpOUkql5W2FplKurfkpgjaib",
    "hmxOXoyLjaSmjF9HXYunr51rQmuRl6mSclRkcmmMuKuNeVFggKGTXnaXhY+Kb3R1cmdtmp+smlBXc3+Wl4+HcoR9bX+CWWuic3yulYN4XVCDwK+NgF9CbKCI",
    "mKx1RVZ6e47Bq3pxXmmHh5ioh2Jgdn2Sp2BObImkm5+Ia215gJGheFdueHeuqIWITjpdi7C3roBXY3qElJSPd194hnabhEhufnyerKGRalNYh6eVlm5Zboan",
    "ioORWEBhhpDBxHVlbnR7lY+RlGZhan6PooxQYnt+kJ+kkGhfbX2YkISYXkV1kZureUBMhqSXsJp6gXBYbZmlgFxveIOvimxyU1mMpZ+tk2xya2p/j4uMfmaE",
    "hnGGZFaBk5qnkoaIc2hqgZ+WfHJiXoypfoaRV1yDd32ywqB7W1JqeJXAgllicpSKiXBTgZ2Pj7SnX1dXVn68t6VyM0hzkKK3dj9ti4GmtJiAb1hPeqWimnhB",
    "Uo+Oi69rPnSdi6S8gGpxX2eNmXd4joB5eXeFhnZedKijo5VhVGZ2iKmpiXZUQmOYopmPcW59gp2ijItVVn6TjZCDTGOPnpySfGFUXIGmwM6RVk9RWYTAuIBW",
    "V3B8n59ZaoqDnbacdlxTYIeepaV7VUZZf5K7uV1JZ3mcvaZ/eG1dY3OTqYNmd3Nwk6h3UmmHmbO2e01RaoaXlZyRXEtmdJK7m2JqfHedsJiDV09yn5WEmYVB",
    "SoKNn8OBQVx+iafBmndjWWl3iK6NU2p9eqSyiFhHan+pz6WEWkdldoSZpXZfeH96lZFlboSToKWWa1BWZJSzlISHYUVfhpito1xZi4iSq5l5WV1qdoalpoVo",
    "UG6Kjq2FUmaGnLSoalZqc3uMjpOHW054maO1h05TeZugpp9wXGRkgZ+EaYN/d4p2i6p2VmWLrbaVW1RkfJCUk3VbdpV9hYNrjZR3e6GwkV9GUoCgmYl3cFt/",
    "n4emi0ZfeHmyzI14bERbhpmslnJOWoWZsJ1YTomRibSVbmtbY46VjYtlZnqJmqCPYlpwdYq5uH9YUWJ6mJigjUVbhISelX6Ne3aMjZWVY09zioeHhmxeiKOG",
    "lqNTQmxzjsjGhWdWUGp+obeRX011k5uZcX2QdGWOsYpuYWB9o4aHl21aZHyauoVWZoGIhLKgjnw6RG+jxKhnS1t6k5+jbmaCeIudoI5zYVVkgK2hZWBzi5ah",
    "hUhUgYibu6SIYE9gdYehq4psU16OnYx+c4qbi412aXtvdoh+faqhbVZNbqGtm29YfJCam4SMd1pld4qqfkx2iIy2lHRhRmqdsLCkW1JpbYGbrKdtQl10nZBm",
    "jpGVlWmClW9bboKTlXyQmWlQZnmYt4BgcoahlXuKjHRPU6CsnG47dp+HlKNhV3F+nLWrfFpXXoKPtcFpPkZrkL6VYYiDb4CFpKljV2p6h56ylGlFTm6ivYFd",
    "aoGgn4eGjm9aWWzAuoRiPF2UobGWRFB3lLu1dmFscm92rceBWkxIbaO+nmtYaoWQtJdcZ3N5jI6dqGpAS2yhuLN8QVVvgry9f3tgUnSGq8GGTkNYc7LFf2xh",
    "aZqgmpJnW2SJr5+Ne1lRXnuvt35RUm+ouqB7Y2Vrh5ejqGs9SGuVurt+U1RngKrCn2pWZH+LmLCEZVlSb56ifIF9fJGHhJR3X217naSNcmhvYGR9pq18UmKJ",
    "mqiOb3p9fXiNsJRsSjlVmL66nlY+XIecsqmAc2pjc5OvnmtfXlt5ooFukZGQkYBqXYGWmaF6bnJfZ3N9nrifakdPb5a8u5FyaWphZJe4p4hXTF5yiZyslYB7",
    "ZGF4j5ShqoNZWm17knZdjqKMfmZoi5qYmHpyfnZwhJych3NdT2OHrp91cX6JkYVvhZyLfHJsdYmOjHFXcJiPdX9+e4uZjIaMinpTVoSunXJYVnimqIxvcXlz",
    "d42prn1pZFZxpKSTc0pYg5eQj4OCgX2MiHd/emhuh6ivh3FoREt4nqCjqH5obF9sorWWfGBceIqBm4FagYl/jHVheZSdpqF7W1hkg7KtfU9LaIqjwZhLU2Z0",
    "nMawi2lbZWBrpryaiVE/c4p1nKB5j45xb3qCiJGHbHSRjmdWYousq5BVVnmFkpeLl4xhXHmLmql/T1ZzhpSaiomJhXpse397koxxeI6Tf3VZTYq1dHKUg4qE",
    "gXuGpYBaa3eNkox2YXqPkpp2T2V6mauehWpxel2CvpV2aEFWl76ekHBVeIZ/m5Z2e3Rwgo2hknVdS2ufsHpgi5t/g2NRm7uJgXVwiXx2hGxkjaWIcHZ9ipB8",
    "doeCh3lVe7GUeYdnWnmUfG+Aka2heFtUdqKfl4l9eWNcZXOau7Z/RUxhfLKnhYyDd2FZhbCfgVxPapqohHN5h4yJgm5pf42Hh358jYB5aktwu6hzbHGPq4RN",
    "XZKsmo99bmxzgIFhcqmskWZOapSfmoNsh45sbYKUmntQUHOpx5BRWXGPq5l6coCKgnRrhKWRgXFMXpKPfZKekYtxVWZ+nqZ4aJmPa3pgS3rAwZleRmmLl5WJ",
    "gZiKVl59p7SCW2BnZo6bb4yol5Z1QEtvn7imfnF4ZWSAgHaUsXtWYnCCoK2PenJ6a12Nq5ODW09qgrK+hllSYYiytYhPWYWVh5Oge3J0a29qgZ+Oj5V+hX9V",
    "VWecyJ1zaWZ0jHdgepyjpHxPZH6XkYKLhX6LgW2Gh4yDTFuEp6V9Y3WXoqSDUVRuhKKpk4BvY3V5YoiOcX+Po6OSYkNZiq6coI5UV2dkhqCTnqFbRXJ+lLyd",
    "bWdhY3eXv656UEdtf3yhkXWeqH5sY11jgbDEnWtfWGWPh22Dh6Kccmdkd5CjmXlZe45yh5WKhm9JU461lXxqbJi1mllGX3+1vYptaF9wfGx/t69yXmN1lbKR",
    "aGluf4qOlod8bmpzcH+olWt5iYaLln9hZHeFlqScgWFjXVeBqrGne1ZxjIOBf3+Fko96fol9fWhebnWjnH55d4uYm39ZV3iMlp+ThV1dfnt5hZKKdHeRjZSR",
    "bWljh6WXmXZbZmJlh5ugrZpNPmqKnbikX1podoalspByXFhxiYiOinmDlo1ub3tnb56gd3eOdWRxfXaHiYaKgIF8foKSh2hkgZ6NkYZhanNhdJ2zpXxTVW+a",
    "sqKMcFtph5GJmp16ZFNWhKKVlIqGg3eFcmJ1epKvmXp1YltympV3iXJfj7KPgn5mZXyFjbCVclxXeo53cYirtHNjZFmAu6d3YmSCjJWnjGhZXHWHkIxuiJ+A",
    "ipxqSF95rLeNfW9ZbHlofZ6coHtHY4eDlrmOWV9yfZ+mi2xWXY6tdIF7UGGWuaahhUg5bqatpI1cU3J3cnWRr7qDW05Se561qXBifXZ3nIt8fG9ze4x+eoyK",
    "g6CkZFFccYmwpYZ/bWZ8h21zi42EiJWShXNncIiHhZ6Tg3tvcHVmZ4aVq41ncXqAo5dre2dphp6rlW9sbV5wmJZba5iqpp5zTVtwnaSdk2ZbboiOjnZaZoSd",
    "m5ZzeI9/W3CUgJaidV1mZHmgpZiKV0BpmK+qo2xJX22CrbyeelJKYYCnk3dtZI24knJtaXR+jZiVooFNVHyBcJGOf6+OS1Fqlbu6lF1cc3yVmod1aoGVfXFe",
    "aoKPrMGJP1BjgLTFk2hWT3uOfoWSnZZgXHl7h42apoRUYY9/jaF1ZnF+gYd5cYmTnpJ+X1Rljrmqj3dWU2mPpoRzfXaAkoB3hoKIj3Rpc46kj3puamxzfZyS",
    "WF6Anaetf0pVd5uuqXleanSAmY2AeG9mZX+qu6BzV1xne57Iom9XQlJ4rbuqjV03WImQnsSjVFBld5yoo4ZbVG6JmJ91UWSLoKWhZk9okqOQk4hnZm2EkGlf",
    "h5+hmmZNZHiFqbGSeWx1enp3eHGTwqJLLEtoqdHLiUJIXHinxqd1WFJlg5ubkoJ8eGlmaoebs6liU2+PjpeLamZrjJB3jX1bdaOxlXFeaX2uo311b3l+mIZc",
    "Y32BkKSBcnxxdY6AgZmMjYVbWGaEnK6bPkNxgqC8oWdYXnyhqpyIdFtqdZCOhn5cdJGNko56eXeDbn60kYF5XVh6mqGYWkZfhavFr3BMV2ODwMOXYkVScpCP",
    "iaOfeVJbb3qWp62DWWiEdImxfl1pe5Cle0RSgbuxtHo0SXqdsbuObVBQcZ+gc3KCf5eZXE12jpWukHV+e3J0hHxriqyggTk0Y5jC1Js9N2KFqMiiX2BkYXyq",
    "j3aNhH2Kh1ZZdqjFnGRad4OSjGtejLOXi1UuYIu1xrttMUhwsMa2bkJZcY6mlYRqZ4iLgXN2fY+Mh3h6mIh/gW5ZcpKjrIJAOFWHu9GjWVpicJCjmpmHYGJ3",
    "jnladqOno3Q6S3WYwq2AcXBodZGFfI2jhHRtO0d4ocHNhjdNcYqmuINheYd9gHRdeYOcuo5FP2CHt8GTaHhvb4qBaZWsj3lmS0VsorutkFdienaTn356joqK",
    "eWhnc3SCo617VWFqe6KwipeXYlp8d3qgqZV/bFdAUXex0sKTTkBZgaqmn5l9ZlxTY4Ggx6lhQ0JajbXCsXZaZWyGj4uIgY2RhGU8UWeR0ciSd1E/aI6pt6V4",
    "a2JUU4S4qp5/QUBphqKyoGmBmHBzlnJYj5mOmYdrQTdnl7fUtnBAQWOKs8y+ejs7T2miwa6QY0hWWmuWwsqbdVxWZImMiZCnoG5QNkVtj8vooVBKUWCXzbmW",
    "dVdXZmGIy6t7alJDbJihnaGDepJ5dYZoV5G3oo9vRkhPZ5i9x7iDQURlham9tYRMSFZllrihiGVVaWlogqzAtKd0PkFwjJinsZVZV0M7apfE3q1VSlVgjr+/",
    "l3djVl9rhbGMiYtfSmR0iKuvm42OZ1JqdICxsYBnY1VRYoSzxKh7ZldojJiLmqKAY19bYpGejop9amJjdYObu7OvhjszY4WcvcF/Tk08SXmt1MqKW15SZqGu",
    "nJuRXEVTa7G0lX9gWFZte427zpd1ZFFifpejpY5+Z1lMWHGiybuhZVVgeYWRkqShe2FVSnG6tYFrVFZ/hoOPqKyslUMvYIGUureQZ1I+PF6Ku+G3fGA+S3iu",
    "rLKrZDtBVILJv5ZiSFZhcYmqv7WTZ0pKaIaht6KLaFJIQmuRzNurY1BPXoynrKCUdGxTQ2O22JVdSkhvkZyeko6VoXFOYHB1kLy+llxBPENqp8vQt3g6PluE",
    "rsG2l2AsQGWi1rx4P0Rfd4aav8CfclJUaYeUiY2kpXxYLz9trNPJi09RVWyXoKCsl21JRFaIz9N+Nj9Yd5uzppWPhnhbYIGGf5eiooZjSzxNd7TMwJNgS1Np",
    "la6rr5dEK1GDw82SWj5QbniEocW5j3RVUm5/koyYuJ1iODNPgcXbs2tLTl15mampqYlYPEh0vt6gSzhSbYyjoJ6iiXlnWnuGhpOhmoJ6aERFZpbEzaNsS1Bu",
    "hJqpq6hwNkFrm8exektFaIR+gp2wtpprV2NpcoKRtsGETCc/Yp3c1INOUlltgJ62vaBaNz9is9Wtf0c9WoCbqZqMiI9/anNraYeqpY55Wz1RgZyzu5B7ZWNq",
    "Z3mizLh8STBKi83FhUhDX4mgfnOMqL+bWE9QV4izw6yHVCg7ZYu82LF8TERedJCgurFsTEVcoNWaa15OVnmmrZx2ZpypjndVSminyqKPWiNNc6O5tZRyZ2tn",
    "aHqay7F2Tz9PiNmzYFNRap6cj4ZnfKyhkYJaVGeOo56piDs2WICkvbSXdlVQZW+UzcGQTjtIbbfFqldIa213i6KcjpChd1htaHuiqZV/YUJeboucqKOKg2pk",
    "Z2J8rbSgeElVgbSraUZgaXWmtodmcqiffIhuTmKGrrahekxEWn15hLnMkV9iWV6BrcOMXGR0jqmhbkhTb3iImbCqbFyDi4mLfW1jgq+sk1QsXH2Sn6ihj3Bo",
    "ZWl2hqy2h1VLdbHCijZBa3B2rL+nbF6CeIOfk3Flf5KHnnlAUYCnoYZmbIaPnH9aZXitsnxoXmWfwpxPOWFubIOkxLWOc05Sd4CGrKqph1JOVFV7qaagj2pt",
    "eXaOjnJugKGXfXd4pp1lTExZcIzKyJJTTH2fqJNTSHm6x6hsMT12mJirh3aHhHJ5cXCOpIl7j4OHiXZybGZmd4RsibuneVNJi86UXXKRm41uVFd4mbyxWjlg",
    "hremX12YnYyXlnRZZHuSkIKRe0BDbaXGuXFAYZOTn5Z0cWNkg56HhpZYPmuapZyFfnRga5e5pGtXXXKprIx7Szpcmcq6gF5rb3qRq5t2aGt7i32ClXhRUYe4",
    "poZycH58fY2CgYuFgpqje11WUUltudO7jmFHWHikq5eEbW97iYSBeHpxWHiOo6F5Z2d3la+cg1xRZ4mmqJ5wcFs2YJWuy6dcUVFus76hdVlfeo6OiIN9cGZn",
    "epeblIGHblZwn7Ofaj5Siri0llo0Q2upxbaQb2VcaJGpknp2fn9xaomdbm2BdmyDkpOjmG5TYo+wmHtpV2OX1KM7P2R/laetl31tdXp8iI6GhpCSe3RwRlKY",
    "t5ZeZpmihHp+aVpws7aCY2V+nax1LkaBk562oW5KWpGknaJwT2l+sbSAW0hSdpmznIR5cH2Ef3VqfaKae1xllpaCh11IbY6WjJefdWKBh4yDd3p+iqO1g0JD",
    "WGeZz5hZcpCkilVUbo+jrKCHeGhheqKCYnBrU2Sz1aJgTF2Vr4xzd42Xi3xoTmCOpJptb4yOfnh0d3xvirm6nHNARGaAsb+BT05kiJuShImdtIFfWFuIq6CS",
    "gmZzWkpur9GjXzhWkcipWD5lmryykW9jXGyJlY90ZWZrfaCkqJZuWFxxiKmvln5lTmJzcZnDkVpfd52gdVligKXLuHlKR2mato5aV1ljjMDKh01PeKGOjZJ4",
    "dX19hnxjXHKWmJOJg3Foc3qAb3uxz5dfRVRti7a4cjhNb5S5qnlugoBnh6OMdXt3bIOUkV5WcJ+9eU5kp7V9Vl17paiWf2F7e4KThltecmh9rsacaVlfaajA",
    "i2VgeIuSi25NbaauhW5mcpOnildaaJq7r4h3dmRyfXhygnhjX4rJtHtpWVeNsqWAcG9rdoCNjYGAfnqDhWJomJmChnFkk6RvbYiUoopVZn8="
}

local function writeEmbeddedU8PcmToWav(b64Parts, outWavPath, sfxKey, pitchFactor)
    local ok = false
    local pf = pitchFactor or 1.0
    pcall(function()
        local b64Str = table.concat(b64Parts)
        local rawBytes = Base64.decode(b64Str, Base64.DEFAULT)
        if not rawBytes then return end

        local tmpU8 = sfxCacheDir .. "/_tmp_" .. sfxKey .. ".u8"
        local fosU8 = FileOutputStream(File(tmpU8))
        fosU8.write(rawBytes)
        fosU8.close()

        local fu = io.open(tmpU8, "rb")
        if not fu then return end
        local uStr = fu:read("*a")
        fu:close()
        pcall(function() File(tmpU8).delete() end)

        local inLen = #uStr
        if inLen < 200 then return end

        local sByte = string.byte
        local sChar = string.char
        local floor = math.floor
        local step = pf / 3.0
        local outFrames = floor((inLen - 2) / step)
        local outBlocks = {}
        local bIdx = 0
        local block = {}
        local bCount = 0

        for i = 0, outFrames - 1 do
            local srcPos = i * step + 1
            local idx1 = floor(srcPos)
            local frac = srcPos - idx1
            local u1 = sByte(uStr, idx1) or 128
            local u2 = sByte(uStr, idx1 + 1) or u1
            local uVal = u1 + (u2 - u1) * frac
            local s16 = floor((uVal - 128) * 235)
            if s16 > 32767 then s16 = 32767
            elseif s16 < -32768 then s16 = -32768 end
            if s16 < 0 then s16 = s16 + 65536 end
            bCount = bCount + 1
            block[bCount] = sChar(s16 % 256, floor(s16 / 256))
            if bCount >= 2048 then
                bIdx = bIdx + 1
                outBlocks[bIdx] = table.concat(block)
                block = {}
                bCount = 0
            end
        end
        if bCount > 0 then
            bIdx = bIdx + 1
            outBlocks[bIdx] = table.concat(block)
        end

        local pcmData = table.concat(outBlocks)
        local fosW = FileOutputStream(File(outWavPath))
        writeWavHeader(fosW, #pcmData, 24000, 1)
        fosW.close()

        local fw = io.open(outWavPath, "ab")
        if fw then
            fw:write(pcmData)
            fw:close()
            ok = true
        end
    end)

    if not ok then
        synthesizeSfxToWav(sfxKey, outWavPath)
    else
        copyFileBinary(outWavPath, publicSfxDir .. "/" .. sfxKey .. ".wav")
    end
    return true
end

local function writeEmbeddedBirdsWav(outWavPath)
    return writeEmbeddedU8PcmToWav(EMBEDDED_BIRDS_U8_B64, outWavPath, "birds", 1.0)
end

local function writeEmbeddedScreamMaleWav(outWavPath)
    return writeEmbeddedU8PcmToWav(EMBEDDED_SCREAM_U8_B64, outWavPath, "scream_male", 1.0)
end

local function writeEmbeddedScreamFemaleWav(outWavPath)
    return writeEmbeddedU8PcmToWav(EMBEDDED_SCREAM_U8_B64, outWavPath, "scream_female", 1.34)
end

local function ensureSfxPackExtracted()
    pcall(function()
        -- Migrate clean studio WAVs (except replaced/upgraded keys) from previous versions
        local skipMigrate = {
            ["birds.wav"] = true,
            ["phone_ring.wav"] = true,
            ["doorbell.wav"] = true,
            ["heartbeat.wav"] = true,
            ["scream_male.wav"] = true,
            ["scream_female.wav"] = true,
            ["car_brakes.wav"] = true,
            ["car_start.wav"] = true,
            ["car_drive.wav"] = true,
            ["car_stop.wav"] = true,
            ["car_door.wav"] = true,
            ["footsteps.wav"] = true
        }
        for _, oldPath in ipairs({"/storage/emulated/0/Download/AudioCraft_SFX_v14", "/storage/emulated/0/Download/AudioCraft_SFX_v13", "/storage/emulated/0/Download/AudioCraft_SFX_v12", "/storage/emulated/0/Download/AudioCraft_SFX_v8"}) do
            local oldDir = File(oldPath)
            if oldDir.exists() then
                local oldFiles = oldDir.listFiles()
                if oldFiles then
                    for i = 0, #oldFiles - 1 do
                        local f = oldFiles[i]
                        local fn = f.getName()
                        if fn:find("%.wav$") and not skipMigrate[fn] and f.length() > 500 then
                            local pubTarget = File(publicSfxDir, fn)
                            if not pubTarget.exists() or pubTarget.length() < 500 then
                                copyFileBinary(f.getPath(), pubTarget.getPath())
                            end
                        end
                    end
                end
            end
        end

        local pubDir = File(publicSfxDir)
        if pubDir.exists() then
            local files = pubDir.listFiles()
            if files then
                for i = 0, #files - 1 do
                    local f = files[i]
                    local fn = f.getName()
                    if fn:find("%.wav$") and f.length() > 500 then
                        local cacheTarget = File(sfxCacheDir, fn)
                        if not cacheTarget.exists() or cacheTarget.length() < 500 then
                            copyFileBinary(f.getPath(), cacheTarget.getPath())
                        end
                    end
                end
            end
        end

        local birdsCache = File(sfxCacheDir, "birds.wav")
        if not birdsCache.exists() or birdsCache.length() < 500 then
            writeEmbeddedBirdsWav(birdsCache.getPath())
        end
        local screamMCache = File(sfxCacheDir, "scream_male.wav")
        if not screamMCache.exists() or screamMCache.length() < 500 then
            writeEmbeddedScreamMaleWav(screamMCache.getPath())
        end
        local screamFCache = File(sfxCacheDir, "scream_female.wav")
        if not screamFCache.exists() or screamFCache.length() < 500 then
            writeEmbeddedScreamFemaleWav(screamFCache.getPath())
        end
        local hbCache = File(sfxCacheDir, "heartbeat.wav")
        if not hbCache.exists() or hbCache.length() < 500 then
            synthesizeSfxToWav("heartbeat", hbCache.getPath())
        end
        local bellCache = File(sfxCacheDir, "doorbell.wav")
        if not bellCache.exists() or bellCache.length() < 500 then
            synthesizeSfxToWav("doorbell", bellCache.getPath())
        end
    end)
end

local function isSfxPackReady()
    ensureSfxPackExtracted()
    local readyCount = 0
    for _, item in ipairs(REQUIRED_SFX_LIST) do
        local f1 = File(sfxCacheDir, item.key .. ".wav")
        local f2 = File(publicSfxDir, item.key .. ".wav")
        if (f1.exists() and f1.length() > 500) or (f2.exists() and f2.length() > 500) then
            readyCount = readyCount + 1
        end
    end
    return readyCount >= 47
end

-- Binary-safe online downloader (uses embedded real PCM for birds & screams, pure warm ding-dong for doorbell, real lub-dub for heartbeat, and official Google Studio OGG for everything else!)
local function downloadSingleSfxOnline(sfxKey, searchQueryText, onDone)
    local cleanKey = (sfxKey or ""):lower():gsub("[^%w_]", "")
    if cleanKey == "" or cleanKey == "none" or BLOCKED_VOCAL_SFX[cleanKey] then
        onDone(false)
        return
    end

    local localWav = sfxCacheDir .. "/" .. cleanKey .. ".wav"
    local existing = File(localWav)
    if existing.exists() and existing.length() > 500 then
        copyFileBinary(localWav, publicSfxDir .. "/" .. cleanKey .. ".wav")
        onDone(true)
        return
    end

    if cleanKey == "birds" then
        writeEmbeddedBirdsWav(localWav)
        onDone(true)
        return
    elseif cleanKey == "scream_male" then
        writeEmbeddedScreamMaleWav(localWav)
        onDone(true)
        return
    elseif cleanKey == "scream_female" then
        writeEmbeddedScreamFemaleWav(localWav)
        onDone(true)
        return
    elseif cleanKey == "doorbell" or cleanKey == "heartbeat" or cleanKey == "rain_drip" or cleanKey == "tea_sip" or cleanKey == "wind_breeze" or cleanKey == "cup_clink" or cleanKey == "phone_dial" or cleanKey == "footsteps_group" or cleanKey == "footsteps_heels" or cleanKey == "footsteps_soft" then
        synthesizeSfxToWav(cleanKey, localWav)
        onDone(true)
        return
    end

    local skipSec = SKIP_SEC_MAP[cleanKey] or 0.0
    local directOgg = DIRECT_OGG_MAP[cleanKey]

    if directOgg and directOgg ~= "" then
        local tmpOgg = sfxCacheDir .. "/_dl_" .. cleanKey .. ".ogg"
        Http.download(directOgg, tmpOgg, function(dlCode, _)
            if dlCode == 200 and decodeMediaFileToWav(tmpOgg, localWav, 5.2, skipSec) then
                pcall(function() File(tmpOgg).delete() end)
                copyFileBinary(localWav, publicSfxDir .. "/" .. cleanKey .. ".wav")
                onDone(true)
            else
                pcall(function() File(tmpOgg).delete() end)
                synthesizeSfxToWav(cleanKey, localWav)
                onDone(true)
            end
        end)
        return
    end

    local q = Uri.encode(searchQueryText or QUERY_MAP[cleanKey] or (cleanKey:gsub("_", " ") .. " sound effect"))
    local myInstantsUrl = "https://www.myinstants.com/en/search/?name=" .. q
    Http.get(myInstantsUrl, function(code, html)
        if code == 200 and html then
            local mp3Rel = tostring(html):match("play%(%x27%s*(/media/sounds/[^%x27]+%.mp3)%s*%x27")
            if mp3Rel then
                local mp3Url = "https://www.myinstants.com" .. mp3Rel
                local tmpMp3 = sfxCacheDir .. "/_dl_" .. cleanKey .. ".mp3"
                Http.download(mp3Url, tmpMp3, function(dlCode, _)
                    if dlCode == 200 and decodeMediaFileToWav(tmpMp3, localWav, 4.5, 0.0) then
                        pcall(function() File(tmpMp3).delete() end)
                        copyFileBinary(localWav, publicSfxDir .. "/" .. cleanKey .. ".wav")
                        onDone(true)
                    else
                        pcall(function() File(tmpMp3).delete() end)
                        synthesizeSfxToWav(cleanKey, localWav)
                        onDone(true)
                    end
                end)
                return
            end
        end
        synthesizeSfxToWav(cleanKey, localWav)
        onDone(true)
    end)
end

-- Simple, Clean Download Sound Effects Dialog
function promptAndDownloadSfxPack(onReadyCallback, onCancelCallback)
    if isSfxPackReady() then
        if onReadyCallback then onReadyCallback() end
        return
    end

    local downloadCancelled = false
    local dViews = {}
    local dLayout = {
        LinearLayout, orientation = "vertical", padding = "22dp", layout_width = "fill", layout_height = "wrap", id = "sfxPromptCard",
        {
            LinearLayout, orientation = "vertical", padding = "14dp", layout_width = "fill", layout_height = "wrap", id = "sfxHeaderBox", layout_marginBottom = "14dp",
            { TextView, id = "sfxTitle", text = "Download Sound Effects", textSize = 18, textColor = "#00E5FF", gravity = "center", typeface = Typeface.DEFAULT_BOLD }
        },
        {
            LinearLayout, orientation = "vertical", padding = "16dp", layout_width = "fill", layout_height = "wrap", id = "sfxStatusBox", layout_marginBottom = "18dp",
            { TextView, id = "sfxMsg", text = "Do you want to download sound effects now?", textSize = 15, textColor = "#EAECEE", gravity = "center" },
            { ProgressBar, id = "sfxProgressBar", style = "?android:attr/progressBarStyleHorizontal", layout_width = "fill", layout_height = "12dp", layout_marginTop = "14dp", max = 100, progress = 1, visibility = View.GONE }
        },
        {
            LinearLayout, id = "sfxBtnRow", orientation = "horizontal", layout_width = "fill", layout_height = "wrap",
            { Button, id = "yesDownloadBtn", text = "DOWNLOAD", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "14dp", layout_marginRight = "6dp", typeface = Typeface.DEFAULT_BOLD },
            { Button, id = "noCancelBtn", text = "CANCEL", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "14dp", layout_marginLeft = "6dp", typeface = Typeface.DEFAULT_BOLD }
        },
        { Button, id = "cancelActiveDownloadBtn", text = "CANCEL", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "14dp", visibility = View.GONE, typeface = Typeface.DEFAULT_BOLD }
    }

    local sfxDlg = LuaDialog(context)
    sfxDlg.setCancelable(false)
    sfxDlg.setView(loadlayout(dLayout, dViews))
    pcall(function()
        dViews.sfxPromptCard.setBackground(createGradientDrawable("#071826", "#102E46", 24, "#00E5FF", 3))
        dViews.sfxHeaderBox.setBackground(createCardDrawable("#0B2438", 16, "#00E5FF", 2))
        dViews.sfxStatusBox.setBackground(createCardDrawable("#091E30", 16, "#00CEC9", 1))
        dViews.yesDownloadBtn.setBackground(createGradientDrawable("#00B894", "#00CEC9", 20, "#55EFC4", 2))
        dViews.noCancelBtn.setBackground(createGradientDrawable("#485460", "#1E272E", 20, "#808E9B", 1))
        dViews.cancelActiveDownloadBtn.setBackground(createGradientDrawable("#C0392B", "#922B21", 20, "#F5B7B1", 2))
    end)

    dViews.noCancelBtn.onClick = function()
        vibrate(30)
        downloadCancelled = true
        sfxDlg.dismiss()
        if onCancelCallback then onCancelCallback() end
    end

    dViews.cancelActiveDownloadBtn.onClick = function()
        vibrate(35)
        downloadCancelled = true
        sfxDlg.dismiss()
        showToast("Download cancelled")
        if onCancelCallback then onCancelCallback() end
    end

    dViews.yesDownloadBtn.onClick = function()
        vibrate(40)
        downloadCancelled = false
        dViews.sfxBtnRow.setVisibility(View.GONE)
        dViews.sfxProgressBar.setVisibility(View.VISIBLE)
        dViews.cancelActiveDownloadBtn.setVisibility(View.VISIBLE)
        dViews.sfxTitle.setText("Downloading...")
        dViews.sfxMsg.setText("1%")
        pcall(function() dViews.sfxProgressBar.setProgress(1) end)

        ensureSfxPackExtracted()
        local totalItems = #REQUIRED_SFX_LIST
        local currentItem = 1

        local function downloadNextItem()
            if downloadCancelled then return end
            if currentItem > totalItems then
                prefs.edit().putBoolean("sfx_pack_v18_installed", true).apply()
                runOnUi(function()
                    if downloadCancelled then return end
                    dViews.sfxMsg.setText("100%")
                    pcall(function() dViews.sfxProgressBar.setProgress(100) end)
                    delay(300, function()
                        if downloadCancelled then return end
                        sfxDlg.dismiss()
                        showToast("Download complete!")
                        if onReadyCallback then onReadyCallback() end
                    end)
                end)
                return
            end

            local item = REQUIRED_SFX_LIST[currentItem]
            local pct = math.max(1, math.floor(((currentItem - 1) / totalItems) * 100))
            runOnUi(function()
                if downloadCancelled then return end
                dViews.sfxMsg.setText(pct .. "%")
                pcall(function() dViews.sfxProgressBar.setProgress(pct) end)
            end)

            downloadSingleSfxOnline(item.key, item.query, function()
                if downloadCancelled then return end
                currentItem = currentItem + 1
                delay(40, downloadNextItem)
            end)
        end

        downloadNextItem()
    end

    sfxDlg.show()
end

-- Exact Keyword Trigger Position Finder for all 45 sounds
local SFX_TRIGGER_KEYWORDS = {
    door_open = {"دروازہ کھول", "دروازہ کھل", "کنڈی کھول", "کھولا", "کھول دیا", "door open", "opened the door", "creak"},
    door_close = {"دروازہ بند", "بند کر دیا", "بند کیا", "زور سے بند", "بند کر", "door close", "closed the door", "slam", "shut"},
    iron_door_open = {"لوہے کا دروازہ کھول", "لوہے کا گیٹ کھول", "آہنی دروازہ کھول", "جیل کا دروازہ کھول", "گیٹ کھول", "تالا توڑا", "تالا کھولا", "iron door open", "iron gate open"},
    iron_door_close = {"لوہے کا دروازہ بند", "لوہے کا گیٹ بند", "آہنی دروازہ بند", "جیل کا دروازہ بند", "گیٹ بند", "iron door close", "iron gate close"},
    knock = {"دستک", "کھٹکھٹ", "knock"},
    doorbell = {"دروازے کی گھنٹی", "گھنٹی بجی", "ڈور بیل", "بیل بجی", "بیل", "doorbell"},
    phone_ring = {"فون بج", "فون کی گھنٹی", "موبائل بج", "ٹیلی فون", "کال آئی", "phone ring", "telephone"},
    thunder = {"بجلی کڑک", "بجلی", "بادل گرج", "گرج", "کڑک", "thunder", "lightning"},
    slap = {"تھپڑ", "تھپر", "چپیڑ", "چپیر", "طمانچ", "چانٹا", "منہ پر مار", "slap"},
    punch = {"مکا", "گھونس", "لات ماری", "مار پیٹ", "punch"},
    gunshot = {"پستول چلا", "پستول چل گیا", "پستول سے", "گولی چلا دی", "گولی چلی", "گولی لگی", "فائرنگ", "فائر کیا", "گولی", "gunshot", "pistol shot", "fired a shot"},
    pistol_cock = {"پستول تان", "پستول نکال", "پستول لوڈ", "بندوق تان", "ٹریگر", "cocked the pistol", "loaded the gun"},
    explosion = {"دھماک", "بم پھٹ", "بلاسٹ", "explosion", "blast"},
    fire = {"آگ بھڑک", "شعلے", "آگ لگ", "fire"},
    chains = {"زنجیروں", "زنجیر", "ہتھکڑی", "بیڑیاں", "chains"},
    water_splash = {"چھپاک", "پانی میں گرا", "splash"},
    dog_bark = {"کتا بھونک", "کتے کے بھونک", "dog bark"},
    car_start = {"گاڑی سٹارٹ", "گاڑی اسٹارٹ", "انجن سٹارٹ", "انجن اسٹارٹ", "کار سٹارٹ", "چابی گھما کر گاڑی", "car start", "engine start"},
    car_drive = {"گاڑی سنسان", "گاڑی چلنے", "گاڑی چلی", "گاڑی تیز", "گاڑی دوڑا", "کار چلنے", "گاڑی روانہ", "چلنے لگی", "car drove", "car driving"},
    car_stop = {"گاڑی بند", "گاڑی رکی", "گاڑی روکی", "گاڑی رک", "انجن بند", "انجن کی آواز تھم", "کار رکی", "car stopped", "engine off"},
    car_brakes = {"بریک لگائی", "بریکوں کی آواز", "بریک ماری", "ٹائروں کی تیز رگڑ", "ٹائر چرچرا", "زور سے بریک", "brakes", "screech"},
    car_horn = {"ہارن", "گاڑی کا ہارن", "car horn"},
    car_door = {"گاڑی کا دروازہ", "کار کا دروازہ", "car door"},
    car_crash = {"گاڑی ٹکرا", "کار ٹکرا", "ایکسیڈنٹ", "car crash"},
    footsteps = {"قدموں کی آہٹ", "قدموں کی آواز", "قدم اٹھاتا", "قدموں کی آوازیں", "آہٹ", "چلنے کی آواز", "دروازے کی طرف بڑھ", "ڈرائنگ روم میں آ", "footsteps"},
    footsteps_wood = {"لکڑی کے فرش", "لکڑی کی سیڑھ", "برآمدے", "قدموں کی آہٹ", "footsteps wood"},
    footsteps_gravel = {"پہاڑی پگڈنڈی", "پتھریلے راستے", "پیدل ہی", "کچے راستے", "footsteps gravel"},
    footsteps_stairs = {"پتھر کی تنگ سیڑھ", "سیڑھیاں اترتا", "سیڑھیاں اترتے", "سیڑھیاں چڑھتا", "سیڑھیاں چڑھتے", "سیڑھیوں", "stairs"},
    footsteps_mud = {"کیچڑ", "گیلی زمین", "mud"},
    footsteps_forest = {"جنگل", "سوکھے پتے", "forest"},
    footsteps_run = {"تیز قدم", "بھاگ کر", "بھاگنے", "دوڑتے", "تیزی سے چلتے", "running"},
    footsteps_group = {"بہت سے قدم", "کئی قدم", "کئی لوگوں کے قدم", "multiple footsteps"},
    footsteps_heels = {"اونچی ایڑی", "ہیلز", "جوتوں کی مخصوص آواز", "high heels"},
    footsteps_soft = {"دبے پاؤں", "چپکے سے", "آہستہ قدم", "چپل", "soft footsteps"},
    ambulance = {"ایمبولینس", "سائرن", "ambulance", "siren"},
    police_siren = {"پولیس کا سائرن", "پولیس سائرن", "پولیس کی گاڑیاں", "police siren"},
    birds = {"چڑیوں", "چڑیا", "پرندے", "پرندوں", "چہچہاہٹ", "چہچہانے", "birds", "chirp"},
    scream_female = {"لڑکی کی چیخ", "عورت کی چیخ", "وہ چیخی", "زور سے چیخی", "خوف کے مارے زور سے چیخی", "چیخ ماری", "woman screamed", "girl screamed"},
    scream_male = {"لڑکے کی چیخ", "آدمی کی چیخ", "مرد کی چیخ", "وہ چیخا", "زور سے چیخا", "دردناک چیخ", "چیخ نکلی", "man screamed", "boy screamed"},
    scream_horror = {"خوفناک چیخ", "ڈراؤنی چیخ", "بھوت کی چیخ", "چڑیل کی چیخ", "خوفناک آواز", "بھیانک چیخ", "ہیبت ناک", "horror scream", "monster scream"},
    crying_female = {"لڑکی رونے", "عورت رونے", "وہ روئی", "رونے لگی", "سسکیاں", "سسکیوں", "زار و قطار روئی", "پھوٹ پھوٹ کر روئی", "woman crying", "girl crying"},
    crying_male = {"لڑکا رونے", "آدمی رونے", "مرد رونے", "وہ رویا", "رونے لگا", "زار و قطار رویا", "پھوٹ پھوٹ کر رونے لگا", "پھوٹ پھوٹ کر رویا", "man crying", "boy crying"},
    glass_break = {"شیشہ ٹوٹ", "کانچ ٹوٹ", "کھڑکی کا شیشہ ٹوٹ", "کھڑکی ٹوٹ", "glass shatter"},
    heartbeat = {"دل کی دھڑکن", "دھڑکن", "heartbeat"},
    rain = {"بارش", "برسات", "موسلادھار", "تیز بارش", "زور پکڑ", "rain"},
    rain_light = {"ہلکی بارش", "بارش بہت ہلکی", "بارش دھیمی", "بوندا باندی", "light rain"},
    rain_roof = {"چھت پر پانی", "چھت پر بارش", "rain on roof"},
    rain_drip = {"بوندوں کے ٹپکنے", "پانی ٹپک", "ٹپ ٹپ", "dripping"},
    rain_indoor = {"گھر کے اندر", "بارش کا یہ شور", "rain indoors"},
    wind = {"تیز ہوا", "آندھی", "طوفان", "سرد ہوا", "طوفانی جھونک", "storm", "wind"},
    wind_breeze = {"ٹھنڈی ہوا", "تازہ ہوا", "ہلکی ہوا", "ہوا چل", "breeze"},
    leaves_rustle = {"پتے ہل", "پتوں کی سرسراہٹ", "درخت کے پتے", "leaves"},
    tea_sip = {"چائے پی", "کافی پی", "چسکی", "sipping tea"},
    cup_clink = {"چائے کے برتن", "چائے کا کپ", "کپ میز پر", "پیالی", "cup", "saucer"},
    phone_dial = {"نمبر ڈائل", "ڈائل کرنے", "رسیور اٹھا", "dialing", "dial"},
    stream_water = {"ندی", "جھرنا", "چشمہ", "stream"},
    sea_waves = {"سمندر", "لہریں", "ساحل", "waves"}
}

local function findSfxTriggerFraction(sentenceText, sfxKey)
    local s = (sentenceText or ""):lower()
    if #s < 4 then return 0.25 end
    local kwList = SFX_TRIGGER_KEYWORDS[sfxKey]
    if kwList then
        for _, kw in ipairs(kwList) do
            local pos = s:find(kw, 1, true)
            if pos then
                local rawFrac = (pos - 1) / math.max(1, #s)
                return math.max(0.08, math.min(0.88, rawFrac))
            end
        end
    end
    return 0.32
end

-- Context & Situation Filter:
-- Blocks action/weapon/door sounds when the sentence is only a verbal threat, future promise, or negation
local function isThreatOrNegatedAction(sent)
    local s = (sent or ""):lower()
    local threatOrNegMarkers = {
        "دوں گا", "دوں گی", "دیں گے", "ماروں گا", "ماروں گی", "چلاؤں گا", "چلاؤں گی",
        "کروں گا", "کروں گی", "کھولوں گا", "توڑ دوں گا", "پھینک دوں گا",
        "مت کھولو", "مت بند", "مت چلا", "مت مار", "نہیں کھولا", "نہیں بند", "نہیں چلائی", "نہیں ماری",
        "نہ کھولو", "نہ چلاؤ", "ورنہ میں", "خبردار",
        "will shoot", "i will ", "i'll shoot", "don't open", "didn't shoot", "did not "
    }
    for _, m in ipairs(threatOrNegMarkers) do
        if s:find(m, 1, true) then
            return true
        end
    end
    return false
end

-- Context-Aware & Surface-Aware Multi-SFX Detector for all 45 Studio Sounds
local function detectAllLocalSfxForSentence(sent)
    local lower = (sent or ""):lower()
    local matches = {}
    local added = {}
    local isThreatOrNeg = isThreatOrNegatedAction(lower)

    local function addMatch(k, pos)
        if k and k ~= "none" and not BLOCKED_VOCAL_SFX[k] and not added[k] then
            added[k] = true
            table.insert(matches, { key = k, pos = pos or 1 })
        end
    end
    local function findFirst(patterns)
        local bestPos = nil
        for _, p in ipairs(patterns) do
            local idx = lower:find(p, 1, true)
            if idx and (not bestPos or idx < bestPos) then
                bestPos = idx
            end
        end
        return bestPos
    end

    local isWeatherEnded = (
        lower:find("ختم ہو چکا", 1, true) or lower:find("ختم ہو گئی", 1, true) or lower:find("تھم چکا", 1, true)
        or lower:find("تھم گئی", 1, true) or lower:find("رک گئی", 1, true) or lower:find("رک چکی", 1, true)
        or lower:find("نہیں ہو رہی", 1, true) or lower:find("storm ended", 1, true) or lower:find("rain stopped", 1, true)
    )

    -- 1. Weather & Nature Ambiences (situation-aware: heavy vs light vs roof vs indoor vs dripping rain, gentle breeze vs storm!)
    local pRainDrip = findFirst({"بوندوں کے ٹپکنے", "پانی ٹپک رہا", "قطرے ٹپک", "ٹپ ٹپ", "water dripping"})
    if pRainDrip then addMatch("rain_drip", pRainDrip) end

    if not isWeatherEnded and not lower:find("بارش نہیں", 1, true) and not lower:find("بارش رک", 1, true) and not lower:find("بارش تھم", 1, true) then
        local pRainRoof = findFirst({"چھت پر پانی گرنے", "چھت پر بارش", "rain on roof"})
        local pRainIndoor = findFirst({"گھر کے اندر بیٹھے ہوئے", "کمرے کے اندر بارش", "کھڑکی سے باہر بارش"})
        local pRainLight = findFirst({"ہلکی بارش", "بارش بہت ہلکی", "بارش دھیمی", "بوندا باندی", "ہلکی پھوار", "light rain", "drizzle"})
        local pRainHeavy = findFirst({"بارش", "برسات", "بھیگ", "مینہ", "rain", "downpour"})

        if pRainDrip then
            addMatch("rain_drip", pRainDrip)
        elseif pRainRoof then
            addMatch("rain_roof", pRainRoof)
        elseif pRainIndoor and pRainHeavy then
            addMatch("rain_indoor", pRainIndoor)
        elseif pRainLight then
            addMatch("rain_light", pRainLight)
        elseif pRainHeavy and not lower:find("یادگار دن", 1, true) and not lower:find("بارش کو محسوس", 1, true) then
            addMatch("rain", pRainHeavy)
        end
    end

    if not isWeatherEnded then
        local pThunder = findFirst({"بجلی کڑک", "بجلی چمک", "بادل گرج", "زوردار بجلی", "گرج چمک", "کڑکنے کی آواز", "thunder", "lightning"})
        if pThunder then addMatch("thunder", pThunder) end

        local pBreeze = findFirst({"ٹھنڈی ہوا", "تازہ ہوا", "ہلکی ہوا", "ہوا کے جھونک", "cool breeze", "light breeze"})
        local pWind = findFirst({"تیز ہوا", "آندھی", "طوفان", "سرد ہوا", "طوفانی جھونک", "strong wind", "storm"})
        if pWind then
            addMatch("wind", pWind)
        elseif pBreeze then
            addMatch("wind_breeze", pBreeze)
        end
    end

    local pLeaves = findFirst({"پتے ہل رہے", "پتوں کی سرسراہٹ", "سوکھے پتے اڑ", "leaves rustl"})
    if pLeaves then addMatch("leaves_rustle", pLeaves) end

    local pTea = findFirst({"چائے پی رہا", "چائے پی رہی", "کافی پی رہا", "چائے کی چسکی", "sipping tea", "drinking tea"})
    if pTea then addMatch("tea_sip", pTea) end

    local pCup = findFirst({"چائے کے برتن", "کپ میز پر", "پیالیاں", "برتن میز پر", "cup on the table", "tea cups"})
    if pCup then addMatch("cup_clink", pCup) end

    local pDial = findFirst({"نمبر ڈائل", "ڈائل کرنے شروع", "ڈائل کیا", "ڈائل کیے", "dialing", "dialed the number"})
    if pDial then addMatch("phone_dial", pDial) end

    local pStream = findFirst({"ندی کا پانی", "ندی بہہ", "جھرنا", "پہاڑی چشمہ", "stream flowing"})
    if pStream then addMatch("stream_water", pStream) end

    local pSea = findFirst({"سمندر کی لہریں", "ساحل سمندر", "سمندر کا شور", "ocean waves"})
    if pSea then addMatch("sea_waves", pSea) end

    local pBirds = findFirst({"پرند", "چڑیا", "چڑیوں", "چہچہا", "birds", "chirp", "songbirds"})
    if pBirds then addMatch("birds", pBirds) end

    local pFire = findFirst({"آگ بھڑک", "شعلے آسمان", "آگ لگ گئی", "آگ کے شعلے", "flames", "fire crackled"})
    if pFire then addMatch("fire", pFire) end

    local pWater = findFirst({"پانی میں گرا", "چھپاک", "پانی اچھلا", "water splash"})
    if pWater then addMatch("water_splash", pWater) end

    local pDog = findFirst({"کتا بھونک", "کتے کے بھونک", "کتوں کے بھونک", "dog bark"})
    if pDog then addMatch("dog_bark", pDog) end

    local pVillage = findFirst({"گاؤں کی رات", "دیہات کی رات", "village night"})
    local pForest = findFirst({"جنگل کی رات", "ویران جنگل", "forest night", "jungle night"})
    -- Only trigger night crickets when actually describing night silence/crickets, NOT time deadlines like "آدھی رات سے پہلے"
    local pInsects = findFirst({"جھینگر", "رات کا سناٹا", "crickets"})
    if pVillage then addMatch("village_night", pVillage)
    elseif pForest then addMatch("forest_night", pForest)
    elseif pInsects then addMatch("night_insects", pInsects) end

    local pAmb = findFirst({"ایمبولینس", "ہسپتال کی گاڑی", "ambulance"})
    local pPoliceSiren = findFirst({"پولیس کا سائرن", "پولیس سائرن", "پولیس کی گاڑی کا سائرن", "police siren"})
    if pAmb then
        addMatch("ambulance", pAmb)
    elseif pPoliceSiren then
        addMatch("police_siren", pPoliceSiren)
    else
        local pGenSiren = findFirst({"سائرن", "siren"})
        if pGenSiren then addMatch("ambulance", pGenSiren) end
    end

    -- 2. Surface-Aware Footsteps (chooses Wood, Gravel/Trail, Stone Stairs, Mud, Forest, Running, or Concrete based on the sentence!)
    local pStepTrigger = findFirst({
        "قدموں کی آہٹ", "قدموں کی آواز", "قدموں کی آوازیں", "چلنے کی آواز", "بھاگنے کی آواز", "سیڑھیاں چڑھنے",
        "سیڑھیاں اترتے", "سیڑھیاں اترتا", "سیڑھیاں چڑھتا", "پیدل ہی", "تیز قدم اٹھاتا", "لمبے لمبے قدم", "قدم اٹھاتا", "تیز قدم اٹھانے", "دبے پاؤں",
        "فرش پر چلتا ہوا", "تیزی سے چلتے ہوئے", "بھاگ کر", "footsteps", "walking", "running"
    })
    if pStepTrigger then
        if lower:find("بہت سے قدم", 1, true) or lower:find("کئی قدم", 1, true) or lower:find("کئی لوگوں کے قدم", 1, true) or lower:find("multiple footsteps", 1, true) then
            addMatch("footsteps_group", pStepTrigger)
        elseif lower:find("اونچی ایڑی", 1, true) or lower:find("ہیلز", 1, true) or lower:find("جوتوں کی مخصوص آواز", 1, true) or lower:find("high heels", 1, true) then
            addMatch("footsteps_heels", pStepTrigger)
        elseif lower:find("دبے پاؤں", 1, true) or lower:find("چپکے سے", 1, true) or lower:find("چپل", 1, true) or lower:find("soft footsteps", 1, true) then
            addMatch("footsteps_soft", pStepTrigger)
        elseif lower:find("لکڑی کے فرش", 1, true) or lower:find("لکڑی کی سیڑھ", 1, true) or lower:find("برآمدے", 1, true) or lower:find("wood floor", 1, true) then
            addMatch("footsteps_wood", pStepTrigger)
        elseif lower:find("کیچڑ", 1, true) or lower:find("گیلی زمین", 1, true) or lower:find("mud", 1, true) then
            addMatch("footsteps_mud", pStepTrigger)
        elseif lower:find("پہاڑی پگڈنڈی", 1, true) or lower:find("پتھریلے راستے", 1, true) or lower:find("پہاڑی راستے", 1, true) or lower:find("کچے راستے", 1, true) or lower:find("gravel", 1, true) then
            addMatch("footsteps_gravel", pStepTrigger)
        elseif lower:find("پتھر کی تنگ سیڑھ", 1, true) or lower:find("سیڑھیاں اترتا", 1, true) or lower:find("سیڑھیاں اترتے", 1, true) or lower:find("سیڑھیاں چڑھتا", 1, true) or lower:find("سیڑھیاں چڑھتے", 1, true) or lower:find("stairs", 1, true) then
            addMatch("footsteps_stairs", pStepTrigger)
        elseif lower:find("جنگل", 1, true) or lower:find("سوکھے پتے", 1, true) or lower:find("forest", 1, true) then
            addMatch("footsteps_forest", pStepTrigger)
        elseif lower:find("بھاگ", 1, true) or lower:find("دوڑ", 1, true) or lower:find("تیز قدم", 1, true) or lower:find("تیزی سے چلتے", 1, true) or lower:find("running", 1, true) then
            addMatch("footsteps_run", pStepTrigger)
        else
            addMatch("footsteps", pStepTrigger)
        end
    end

    local pHeart = findFirst({"دل کی دھڑکن", "دھڑکن تیز", "دل دھڑک", "heartbeat"})
    if pHeart then addMatch("heartbeat", pHeart) end

    -- 3. Screams (Horror, Female, Male) & Crying (Female, Male)
    if not isThreatOrNeg then
        local pHorrorScream = findFirst({
            "خوفناک چیخ", "ڈراؤنی چیخ", "بھوت کی چیخ", "چڑیل کی چیخ", "بھیانک چیخ", "ہیبت ناک چیخ",
            "خوفناک آواز", "ڈراؤنی آواز", "وحشت ناک چیخ", "horror scream", "monster scream", "demonic scream"
        })
        local pFemScream = findFirst({
            "لڑکی کی چیخ", "عورت کی چیخ", "لڑکی چیخی", "عورت چیخی", "وہ چیخی", "زور سے چیخی",
            "خوف سے چیخی", "خوف کے مارے زور سے چیخی", "چلا کر بولی", "اس نے چیخ ماری",
            "woman screamed", "girl screamed", "she screamed"
        })
        local pMaleScream = findFirst({
            "لڑکے کی چیخ", "آدمی کی چیخ", "مرد کی چیخ", "لڑکا چیخا", "آدمی چیخا", "وہ چیخا",
            "زور سے چیخا", "درد سے چیخا", "دردناک چیخ", "چیخ نکلی", "چیخ نکل گئی", "چیخنے کی آواز",
            "man screamed", "boy screamed", "he screamed"
        })
        if pHorrorScream then
            addMatch("scream_horror", pHorrorScream)
        elseif pFemScream then
            addMatch("scream_female", pFemScream)
        elseif pMaleScream then
            if lower:find("لڑکی", 1, true) or lower:find("عورت", 1, true) or lower:find("چیخی", 1, true) or lower:find("ثنا", 1, true) then
                addMatch("scream_female", pMaleScream)
            else
                addMatch("scream_male", pMaleScream)
            end
        end

        local pFemCry = findFirst({
            "لڑکی رونے لگی", "لڑکی کے رونے", "عورت رونے لگی", "عورت کے رونے", "وہ رونے لگی",
            "پھوٹ پھوٹ کر روئی", "زار و قطار روئی", "رو پڑی", "سسکیاں لینے لگی", "سسکیاں لیتے ہوئے", "سسکیوں کی آواز",
            "بے بسی کی شدت سے رونے لگی", "بے بسی سے رونے لگی", "رونے لگی", "روتے ہوئے بولی", "woman crying", "girl crying", "she cried", "she sobbed"
        })
        local pMaleCry = findFirst({
            "لڑکا رونے لگا", "لڑکے کے رونے", "آدمی رونے لگا", "مرد کے رونے", "وہ رونے لگا",
            "پھوٹ پھوٹ کر رونے لگا", "پھوٹ پھوٹ کر رویا", "زار و قطار رونے لگا", "زار و قطار رویا", "رونے لگا", "رو پڑا",
            "آنسو بہانے لگا", "رونے کی آواز", "روتے ہوئے بولا", "man crying", "boy crying", "he cried", "he sobbed"
        })
        if pFemCry then
            addMatch("crying_female", pFemCry)
        elseif pMaleCry then
            if lower:find("لڑکی", 1, true) or lower:find("عورت", 1, true) or lower:find("روئی", 1, true) or lower:find("لگی", 1, true) then
                addMatch("crying_female", pMaleCry)
            else
                addMatch("crying_male", pMaleCry)
            end
        end
    end

    -- 4. Doors (Wooden vs Iron/Metal/Jail/Gate), Chains, Weapons, Vehicles & Physical Actions
    if not isThreatOrNeg then
        local pBell = findFirst({"کال بیل", "دروازے کی گھنٹی", "گھنٹی بجی", "ڈور بیل", "بیل بجی", "call bell", "doorbell"})
        if pBell and not lower:find("فون", 1, true) and not lower:find("ٹیلی فون", 1, true) then
            addMatch("doorbell", pBell)
        end

        local pKnock = findFirst({"دستک", "کھٹکھٹایا", "کھٹکھٹاہٹ", "دروازہ بجایا", "knock"})
        if pKnock then addMatch("knock", pKnock) end

        local pChains = findFirst({"زنجیروں میں جکڑا", "زنجیر ہلی", "زنجیروں کی آواز", "ہتھکڑی", "chains rattled"})
        if pChains then addMatch("chains", pChains) end

        local isIronContext = (
            lower:find("لوہے", 1, true) or lower:find("آہنی", 1, true) or lower:find("جیل", 1, true)
            or lower:find("سلاخ", 1, true) or lower:find("گیٹ", 1, true) or lower:find("کوٹھڑی", 1, true)
            or lower:find("تالا", 1, true)
            or lower:find("iron", 1, true) or lower:find("metal", 1, true) or lower:find("gate", 1, true) or lower:find("jail", 1, true)
        )

        local pDoorOpen = findFirst({
            "دروازہ کھولا", "دروازہ کھلا", "دروازہ کھول دیا", "دروازہ کھلنے", "گیٹ کھولا", "گیٹ کھلا",
            "کنڈی کھولی", "تالا کھولا", "تالا توڑا", "opened the door", "opened the gate", "door creaked open"
        })
        if pDoorOpen then
            if isIronContext and not lower:find("لکڑی", 1, true) then
                addMatch("iron_door_open", pDoorOpen)
            else
                addMatch("door_open", pDoorOpen)
            end
        end

        local pDoorClose = findFirst({
            "دروازہ بند کر دیا", "دروازہ بند کیا", "کھڑکی بند کر دی", "کھڑکی بند کی", "دروازہ بند ہوا", "زور سے بند کیا", "دروازہ بند کرنے",
            "گیٹ بند کیا", "گیٹ بند کر دیا", "گیٹ بند ہوا", "closed the door", "slammed the door", "shut the door"
        })
        if pDoorClose then
            if isIronContext and not lower:find("لکڑی", 1, true) then
                addMatch("iron_door_close", pDoorClose)
            else
                addMatch("door_close", pDoorClose)
            end
        end

        local pSlap = findFirst({"تھپڑ مارا", "تھپڑ کی آواز", "تھپڑ رسید", "چپیڑ ماری", "طمانچہ مارا", "چانٹا مارا", "زوردار تھپڑ", "slapped"})
        if pSlap then addMatch("slap", pSlap) end

        local pPunch = findFirst({"مکا مارا", "گھونسہ مارا", "لات ماری", "بھرپور مکا", "punched"})
        if pPunch then addMatch("punch", pPunch) end

        local pCock = findFirst({"پستول تان", "پستول لوڈ", "پستول نکالا", "بندوق تان", "cocked the pistol", "loaded the gun"})
        local pGun = findFirst({
            "گولی چلا دی", "گولی چلی", "گولی چلنے کی آواز", "پستول چلا", "پستول چل گیا", "پستول چلنے", "پستول سے فائر",
            "فائر کیا", "فائرنگ کی", "فائر ہوا", "گولی لگی", "ٹھاہ کی آواز", "fired a shot", "gunshot rang", "pistol fired"
        })
        if pGun then
            addMatch("gunshot", pGun)
        elseif pCock then
            addMatch("pistol_cock", pCock)
        end

        local pExp = findFirst({"دھماکہ ہوا", "دھماکے کی آواز", "زوردار دھماکہ", "بم پھٹا", "بلاسٹ ہوا", "exploded", "explosion"})
        if pExp then addMatch("explosion", pExp) end

        local pGlass = findFirst({"شیشہ ٹوٹا", "شیشہ ٹوٹنے", "کانچ ٹوٹا", "کھڑکی کا شیشہ ٹوٹا", "کھڑکی ٹوٹی", "چھن سے ٹوٹا", "glass shattered"})
        if pGlass then addMatch("glass_break", pGlass) end

        local pVehicleWord = findFirst({"گاڑی", "کار", "جیپ", "انجن", "ٹائر", "car", "engine", "tire"})
        local pCarStart = findFirst({
            "گاڑی سٹارٹ", "گاڑی اسٹارٹ", "انجن سٹارٹ", "انجن اسٹارٹ", "کار سٹارٹ", "کار اسٹارٹ",
            "گاڑی کا انجن چلایا", "چابی گھما کر گاڑی", "started the car", "engine started"
        })
        if not pCarStart and pVehicleWord then
            local pSt = findFirst({"سٹارٹ کی", "اسٹارٹ کی", "سٹارٹ کیا", "اسٹارٹ کیا", "سٹارٹ ہوئی"})
            if pSt then pCarStart = pSt end
        end
        if pCarStart then addMatch("car_start", pCarStart) end

        local pCarBrakes = findFirst({
            "بریک لگائی", "بریکوں کی آواز", "زور سے بریک", "بریک ماری", "ٹائر چرچرائے", "ٹائروں کی تیز رگڑ", "ٹائروں کی آواز",
            "گاڑی پھسلتی ہوئی", "slammed the brakes", "brakes screeched", "tires screeched"
        })
        if pCarBrakes then addMatch("car_brakes", pCarBrakes) end

        local pCarStop = findFirst({
            "گاڑی بند کی", "گاڑی بند ہو گئی", "گاڑی رکی", "گاڑی روکی", "گاڑی رک گئی", "انجن بند کیا",
            "انجن بند ہو گیا", "کار رکی", "کار روکی", "گاڑیاں رک گئیں",
            "car stopped", "turned off the engine", "engine stopped"
        })
        if pCarStop then addMatch("car_stop", pCarStop) end

        local pCarDoor = findFirst({"گاڑی کا دروازہ کھولا", "گاڑی کا دروازہ بند", "کار کا دروازہ", "car door"})
        if pCarDoor then addMatch("car_door", pCarDoor) end

        local pCarCrash = findFirst({"گاڑی ٹکرا", "کار ٹکرا", "car crashed"})
        if pCarCrash and not pCarBrakes then addMatch("car_crash", pCarCrash) end

        local pCarDrive = findFirst({
            "گاڑی چلنے", "گاڑی چلی", "گاڑی تیز", "گاڑی دوڑائی", "گاڑی روانہ", "کار چلنے", "کار تیز",
            "گاڑی سڑک پر دوڑ", "گاڑی سنسان سڑک پر", "car drove", "car sped", "driving fast"
        })
        if not pCarDrive and pVehicleWord and not pCarStop and not pCarStart and not lower:find("نہیں جا سکتی", 1, true) and not lower:find("سلامت کھڑی تھی", 1, true) then
            local pMove = findFirst({"چلنے لگی", "تیزی سے چل", "دوڑ رہی تھی", "آگے بڑھ رہی تھی"})
            if pMove then pCarDrive = pMove end
        end
        if pCarDrive then addMatch("car_drive", pCarDrive) end

        local pHorn = findFirst({"ہارن بجا", "ہارن کی آواز", "گاڑی کا ہارن", "زور سے ہارن", "car horn", "honked"})
        if pHorn then addMatch("car_horn", pHorn) end

        local pPhone = findFirst({"فون بجا", "فون کی گھنٹی", "موبائل بجا", "ٹیلی فون کی گھنٹی", "فون بجنے", "کال آئی", "phone rang", "telephone rang"})
        if pPhone then addMatch("phone_ring", pPhone) end
    end

    table.sort(matches, function(a, b) return a.pos < b.pos end)
    local list = {}
    for _, m in ipairs(matches) do
        table.insert(list, m.key)
    end
    return list
end

-- Parse WAV header, align peak for impact/door sounds, and compute balanced studio normalization gain
local function parseWavMetadata(wStr, sfxKey, isAmbient)
    if not wStr or #wStr <= 44 then return nil end
    local sByte = string.byte
    local floor = math.floor
    local max = math.max
    local min = math.min
    local abs = math.abs

    local b23, b24 = sByte(wStr, 23, 24)
    local numChannels = (b23 or 1) + (b24 or 0) * 256
    if numChannels < 1 or numChannels > 2 then numChannels = 1 end

    local b25, b26, b27, b28 = sByte(wStr, 25, 28)
    local sampleRate = (b25 or 0) + (b26 or 0) * 256 + (b27 or 0) * 65536 + (b28 or 0) * 16777216
    if sampleRate < 4000 or sampleRate > 96000 then sampleRate = 24000 end

    local b35, b36 = sByte(wStr, 35, 36)
    local bitsPerSample = (b35 or 16) + (b36 or 0) * 256
    if bitsPerSample ~= 8 and bitsPerSample ~= 16 then bitsPerSample = 16 end

    local dPos = wStr:find("data", 13, true)
    local dataStart = (dPos and (dPos + 8)) or 45
    if dataStart > #wStr then dataStart = 45 end

    local bytesPerSample = floor(bitsPerSample / 8)
    local frameSize = numChannels * bytesPerSample
    local rawTotalFrames = floor((#wStr - dataStart + 1) / frameSize)
    if rawTotalFrames <= 10 then return nil end

    local peakAmp = 1
    local peakFrame = 0
    local step = max(1, floor(rawTotalFrames / 1600))
    for f = 0, rawTotalFrames - 1, step do
        local bPos = dataStart + f * frameSize
        local slo, shi = sByte(wStr, bPos, bPos + 1)
        if slo and shi then
            local v = shi * 256 + slo
            if v >= 32768 then v = v - 65536 end
            local av = abs(v)
            if av > peakAmp then
                peakAmp = av
                peakFrame = f
            end
        end
    end

    local firstActiveFrame = 0
    if peakAmp > 180 then
        if sfxKey == "door_open" or sfxKey == "iron_door_open" or sfxKey == "car_start" or sfxKey == "car_stop" or sfxKey == "car_brakes" then
            firstActiveFrame = max(0, peakFrame - floor(sampleRate * 0.35))
        elseif not isAmbient and SINGLE_IMPACT_SFX_SET[sfxKey] then
            firstActiveFrame = max(0, peakFrame - floor(sampleRate * 0.08))
        else
            local thresh = max(150, floor(peakAmp * 0.14))
            for f = 0, min(rawTotalFrames - 1, floor(sampleRate * 2.5)), 8 do
                local bPos = dataStart + f * frameSize
                local slo, shi = sByte(wStr, bPos, bPos + 1)
                if slo and shi then
                    local v = shi * 256 + slo
                    if v >= 32768 then v = v - 65536 end
                    if abs(v) >= thresh then
                        firstActiveFrame = max(0, f - floor(sampleRate * 0.02))
                        break
                    end
                end
            end
            if sfxKey == "rain" and rawTotalFrames > floor(sampleRate * 1.8) then
                firstActiveFrame = max(firstActiveFrame, floor(sampleRate * 0.6))
            end
        end
    end

    local adjustedDataStart = dataStart + firstActiveFrame * frameSize
    local activeFrames = rawTotalFrames - firstActiveFrame
    if activeFrames <= 10 then
        adjustedDataStart = dataStart
        activeFrames = rawTotalFrames
    end

    local maxAllowedGain = FOOTSTEP_SFX_SET[sfxKey] and 12.0 or 20.0
    local normGain = 22000.0 / max(300, peakAmp)
    if normGain < 0.55 then normGain = 0.55
    elseif normGain > maxAllowedGain then normGain = maxAllowedGain end

    local pitchMult = 1.0
    if sfxKey == "crying_female" then
        pitchMult = 1.30
    end

    return {
        raw = wStr,
        channels = numChannels,
        rate = sampleRate,
        bits = bitsPerSample,
        dataStart = adjustedDataStart,
        frameSize = frameSize,
        totalFrames = activeFrames,
        rateRatio = (sampleRate / 24000.0) * pitchMult,
        normGain = normGain,
        warmFilter = WARM_FILTER_SFX_SET[sfxKey] and true or false
    }
end

local ambientPhaseTracker = {}

local function smoothVoiceEdges(voiceBytes)
    if not voiceBytes then return voiceBytes end
    local ok, smoothed = pcall(function()
        local tmpIn = sfxCacheDir .. "/_tmp_edge_in.pcm"
        local fos = FileOutputStream(File(tmpIn))
        fos.write(voiceBytes)
        fos.close()

        local f = io.open(tmpIn, "rb")
        if not f then return voiceBytes end
        local vStr = f:read("*a")
        f:close()

        local vLen = #vStr
        if vLen % 2 ~= 0 then
            vLen = vLen - 1
            vStr = vStr:sub(1, vLen)
        end
        local totalFrames = math.floor(vLen / 2)
        if totalFrames < 1600 then return voiceBytes end

        local sByte = string.byte
        local sChar = string.char
        local floor = math.floor
        local fadeInFrames = 600
        local fadeOutFrames = 840

        local headParts = {}
        for i = 0, fadeInFrames - 1 do
            local bPos = i * 2 + 1
            local lo, hi = sByte(vStr, bPos, bPos + 1)
            local v = hi * 256 + lo
            if v >= 32768 then v = v - 65536 end
            local gained = floor(v * (i / fadeInFrames))
            if gained < 0 then gained = gained + 65536 end
            headParts[i + 1] = sChar(gained % 256, floor(gained / 256))
        end

        local tailParts = {}
        local tailStartFrame = totalFrames - fadeOutFrames
        for i = 0, fadeOutFrames - 1 do
            local frameIdx = tailStartFrame + i
            local bPos = frameIdx * 2 + 1
            local lo, hi = sByte(vStr, bPos, bPos + 1)
            local v = hi * 256 + lo
            if v >= 32768 then v = v - 65536 end
            local gained = floor(v * ((fadeOutFrames - 1 - i) / fadeOutFrames))
            if gained < 0 then gained = gained + 65536 end
            tailParts[i + 1] = sChar(gained % 256, floor(gained / 256))
        end

        local midStr = vStr:sub(fadeInFrames * 2 + 1, tailStartFrame * 2)
        local outStr = table.concat(headParts) .. midStr .. table.concat(tailParts)

        local tmpOut = sfxCacheDir .. "/_tmp_edge_out.pcm"
        local fo = io.open(tmpOut, "wb")
        if not fo then return voiceBytes end
        fo:write(outStr)
        fo:close()

        local outFile = File(tmpOut)
        local outLen = math.floor(tonumber(outFile.length()) or 0)
        local outBuf = byte[outLen]
        local fis = FileInputStream(outFile)
        fis.read(outBuf)
        fis.close()
        return outBuf
    end)
    if ok and smoothed then return smoothed end
    return voiceBytes
end

-- Self-Correcting Pause-Valley Slicer for Multi-Sentence Studio Chunks
local function sliceChunkPcmIntoClauses(pcmStr, clauses)
    local N = #clauses
    local totalBytes = #pcmStr - (#pcmStr % 2)
    if N <= 1 or totalBytes < 4800 then
        return { pcmStr:sub(1, totalBytes) }
    end

    local sByte = string.byte
    local floor = math.floor
    local max = math.max
    local min = math.min

    local totalFrames = floor(totalBytes / 2)
    local winFrames = 600
    local numWins = floor(totalFrames / winFrames)
    if numWins < N * 4 then
        local slices = {}
        local prevByte = 0
        for i = 1, N do
            local endByte = (i == N) and totalBytes or (floor((i / N) * totalFrames) * 2)
            table.insert(slices, pcmStr:sub(prevByte + 1, endByte))
            prevByte = endByte
        end
        return slices
    end

    local rms = {}
    for w = 0, numWins - 1 do
        local sumSq = 0
        local baseByte = w * winFrames * 2 + 1
        for f = 0, winFrames - 1, 6 do
            local bPos = baseByte + f * 2
            local lo, hi = sByte(pcmStr, bPos, bPos + 1)
            if lo and hi then
                local v = hi * 256 + lo
                if v >= 32768 then v = v - 65536 end
                sumSq = sumSq + (v * v)
            end
        end
        rms[w + 1] = math.sqrt(sumSq / 100)
    end

    local slices = {}
    local prevWin = 0
    local prevByte = 0

    for i = 1, N - 1 do
        local remChars = 0
        for j = i, N do
            remChars = remChars + max(8, #(clauses[j].text or ""))
        end
        local sc = max(8, #(clauses[i].text or ""))
        local expWin = prevWin + floor((sc / max(1, remChars)) * (numWins - prevWin))

        local minSearch = max(prevWin + 10, expWin - 48)
        local maxSearch = min(numWins - (N - i) * 10, expWin + 48)
        if maxSearch < minSearch then
            minSearch = max(prevWin + 4, min(expWin, numWins - 4))
            maxSearch = minSearch
        end

        local localSum = 0
        local localCnt = 0
        for w = minSearch, maxSearch do
            localSum = localSum + (rms[w + 1] or 0)
            localCnt = localCnt + 1
        end
        local localMean = (localCnt > 0) and (localSum / localCnt) or 1000.0

        local bestW = expWin
        local bestScore = 1e18
        for w = minSearch, maxSearch do
            local ePrev = rms[max(1, w)] or 0
            local eCur = rms[w + 1] or 0
            local eNext = rms[min(numWins, w + 2)] or 0
            local valleyE = (ePrev * 0.25 + eCur * 0.50 + eNext * 0.25)
            local silenceRatio = (valleyE + 35.0) / (localMean + 35.0)
            local distPenalty = 0.22 * math.pow((w - expWin) / 48.0, 2)
            local score = silenceRatio + distPenalty
            if score < bestScore then
                bestScore = score
                bestW = w
            end
        end

        prevWin = bestW
        local cutByte = bestW * winFrames * 2
        if cutByte <= prevByte then cutByte = min(totalBytes, prevByte + 2400) end
        table.insert(slices, pcmStr:sub(prevByte + 1, cutByte))
        prevByte = cutByte
    end

    table.insert(slices, pcmStr:sub(prevByte + 1, totalBytes))
    return slices
end

-- Mixes a single sentence's raw PCM string with its detected sound effects at their exact keyword positions
local function mixClausePcmStringWithSfx(vStr, sfxWavPathsAndKeys, sentenceText)
    if not vStr or #vStr < 20 then return vStr or "" end
    local vLen = #vStr - (#vStr % 2)
    vStr = vStr:sub(1, vLen)
    if not sfxWavPathsAndKeys or #sfxWavPathsAndKeys == 0 then
        return vStr
    end

    local ok, mixedStr = pcall(function()
        local ambientTracks = {}
        local actionTracks = {}

        for _, item in ipairs(sfxWavPathsAndKeys) do
            if not BLOCKED_VOCAL_SFX[item.key] then
                local fs = io.open(item.path, "rb")
                if fs then
                    local wStr = fs:read("*a")
                    fs:close()
                    local isAmb = AMBIENT_SFX_SET[item.key] and true or false
                    local meta = parseWavMetadata(wStr, item.key, isAmb)
                    if meta then
                        meta.key = item.key
                        meta.gainWeight = item.gainWeight or 1.0
                        meta.lpState = 0.0
                        if isAmb then
                            table.insert(ambientTracks, meta)
                        else
                            table.insert(actionTracks, meta)
                        end
                    end
                end
            end
        end

        if #ambientTracks == 0 and #actionTracks == 0 then
            return vStr
        end

        local voiceFrames = math.floor(vLen / 2)
        local floor = math.floor
        local min = math.min
        local max = math.max
        local abs = math.abs
        local sByte = string.byte
        local sChar = string.char

        local firstSpeechFrame = 0
        local lastSpeechFrame = voiceFrames - 1
        for f = 0, voiceFrames - 1, 16 do
            local bPos = f * 2 + 1
            local lo, hi = sByte(vStr, bPos, bPos + 1)
            if lo and hi then
                local v = hi * 256 + lo
                if v >= 32768 then v = v - 65536 end
                if abs(v) > 450 then
                    firstSpeechFrame = f
                    break
                end
            end
        end
        for f = voiceFrames - 1, firstSpeechFrame, -16 do
            local bPos = f * 2 + 1
            local lo, hi = sByte(vStr, bPos, bPos + 1)
            if lo and hi then
                local v = hi * 256 + lo
                if v >= 32768 then v = v - 65536 end
                if abs(v) > 450 then
                    lastSpeechFrame = f
                    break
                end
            end
        end

        local speechSpanFrames = max(2400, lastSpeechFrame - firstSpeechFrame)
        local totalOutFrames = voiceFrames

        for _, amb in ipairs(ambientTracks) do
            local kwFrac = findSfxTriggerFraction(sentenceText, amb.key)
            -- Align EVERY ambient sound directly to its exact spoken keyword inside the sentence!
            amb.startOutFrame = firstSpeechFrame + floor(kwFrac * speechSpanFrames * 0.96)
        end

        for idx, act in ipairs(actionTracks) do
            local kwFrac = findSfxTriggerFraction(sentenceText, act.key)
            local targetFrame = firstSpeechFrame + floor(kwFrac * speechSpanFrames * 0.96)
            if #actionTracks > 1 and idx > 1 then
                local prevStart = actionTracks[idx - 1].startOutFrame or firstSpeechFrame
                local minNextStart = prevStart + floor(24000 * 0.52)
                act.startOutFrame = max(targetFrame, min(lastSpeechFrame, minNextStart))
            else
                act.startOutFrame = targetFrame
            end
            local maxActFrames = SINGLE_IMPACT_SFX_SET[act.key] and 34800 or 45600
            local rawOutDur = floor(act.totalFrames / act.rateRatio)
            act.outDurationFrames = min(maxActFrames, rawOutDur)

            -- Keep exact voiceFrames length so spoken flow stays 100% continuous!
        end

        local outChunks = {}
        local chunkIdx = 0
        local blockBytes = {}
        local bCount = 0

        for outFrame = 0, totalOutFrames - 1 do
            local vSample = 0
            if outFrame < voiceFrames then
                local vBytePos = outFrame * 2 + 1
                local vlo, vhi = sByte(vStr, vBytePos, vBytePos + 1)
                if vlo and vhi then
                    vSample = vhi * 256 + vlo
                    if vSample >= 32768 then vSample = vSample - 65536 end
                end
            end

            local ambSum = 0
            local actSum = 0
            local isActionPlaying = false

            for _, amb in ipairs(ambientTracks) do
                local relAmb = outFrame - (amb.startOutFrame or 0)
                if relAmb >= 0 then
                    local ambDur = totalOutFrames - (amb.startOutFrame or 0)
                    local phaseStart = ambientPhaseTracker[amb.key] or 0
                    local srcFrame = (floor(relAmb * amb.rateRatio) + phaseStart) % amb.totalFrames
                    local bPos = amb.dataStart + srcFrame * amb.frameSize
                    local slo, shi = sByte(amb.raw, bPos, bPos + 1)
                    if slo and shi then
                        local sVal = shi * 256 + slo
                        if sVal >= 32768 then sVal = sVal - 65536 end
                        if amb.warmFilter then
                            amb.lpState = amb.lpState * 0.70 + sVal * 0.30
                            sVal = amb.lpState
                        end
                        local fadeFrames = min(6000, floor(ambDur * 0.20))
                        local env = 1.0
                        if fadeFrames > 10 then
                            if relAmb < fadeFrames then
                                env = relAmb / fadeFrames
                            elseif (ambDur - relAmb) < fadeFrames then
                                env = (ambDur - relAmb) / fadeFrames
                            end
                        end
                        local level = 0.42
                        if amb.key == "rain" or amb.key == "wind" or amb.key == "fire" then level = 0.30
                        elseif amb.key == "rain_light" or amb.key == "rain_indoor" or amb.key == "wind_breeze" or amb.key == "leaves_rustle" then level = 0.24
                        elseif amb.key == "rain_roof" then level = 0.34
                        elseif amb.key == "rain_drip" then level = 0.30
                        elseif FOOTSTEP_SFX_SET[amb.key] then level = 0.38
                        elseif amb.key == "birds" then level = 0.22
                        elseif amb.key == "car_drive" then level = 0.42 end
                        ambSum = ambSum + (sVal * amb.normGain * level * amb.gainWeight * env)
                    end
                end
            end

            for _, act in ipairs(actionTracks) do
                local relOut = outFrame - act.startOutFrame
                if relOut >= 0 and relOut < act.outDurationFrames then
                    isActionPlaying = true
                    local srcFrame = floor(relOut * act.rateRatio)
                    if srcFrame < act.totalFrames then
                        local bPos = act.dataStart + srcFrame * act.frameSize
                        local slo, shi = sByte(act.raw, bPos, bPos + 1)
                        if slo and shi then
                            local sVal = shi * 256 + slo
                            if sVal >= 32768 then sVal = sVal - 65536 end
                            local env = 1.0
                            local fadeInLen = min(720, floor(act.outDurationFrames * 0.05))
                            local fadeOutLen = min(4800, floor(act.outDurationFrames * 0.25))
                            if fadeInLen > 10 and relOut < fadeInLen then
                                env = relOut / fadeInLen
                            elseif fadeOutLen > 10 and (act.outDurationFrames - relOut) < fadeOutLen then
                                env = (act.outDurationFrames - relOut) / fadeOutLen
                            end
                            local actLevel = (act.key == "tea_sip") and 0.36 or 0.76
                            actSum = actSum + (sVal * act.normGain * actLevel * env)
                        end
                    end
                end
            end

            local voiceGain = isActionPlaying and 0.90 or 0.98
            local ambDuck = isActionPlaying and 0.45 or 1.0
            local mixed = floor(vSample * voiceGain + ambSum * ambDuck + actSum)
            if mixed > 32767 then mixed = 32767
            elseif mixed < -32768 then mixed = -32768 end
            if mixed < 0 then mixed = mixed + 65536 end

            local mlo = mixed % 256
            local mhi = floor(mixed / 256)
            bCount = bCount + 1
            blockBytes[bCount] = sChar(mlo, mhi)

            if bCount >= 2048 then
                chunkIdx = chunkIdx + 1
                outChunks[chunkIdx] = table.concat(blockBytes)
                blockBytes = {}
                bCount = 0
            end
        end

        for _, amb in ipairs(ambientTracks) do
            local prev = ambientPhaseTracker[amb.key] or 0
            ambientPhaseTracker[amb.key] = (prev + floor(totalOutFrames * amb.rateRatio)) % amb.totalFrames
        end

        if bCount > 0 then
            chunkIdx = chunkIdx + 1
            outChunks[chunkIdx] = table.concat(blockBytes)
        end

        return table.concat(outChunks)
    end)

    if ok and mixedStr and #mixedStr > 0 then return mixedStr end
    return vStr
end

local function processStudioChunkWithSfx(chunkVoiceBytes, chunkClauses, callback)
    if not chunkVoiceBytes then
        callback(nil)
        return
    end

    ensureSfxPackExtracted()
    local neededKeys = {}
    local seenKey = {}
    for _, cl in ipairs(chunkClauses) do
        for _, it in ipairs(cl.sfxItems or {}) do
            local k = (type(it) == "table") and it.key or tostring(it)
            if k and k ~= "none" and not BLOCKED_VOCAL_SFX[k] and not seenKey[k] then
                seenKey[k] = true
                table.insert(neededKeys, k)
            end
        end
    end

    if #neededKeys == 0 then
        callback(smoothVoiceEdges(chunkVoiceBytes))
        return
    end

    local keyPathMap = {}
    local kIdx = 1

    local function ensureNextKey()
        if kIdx > #neededKeys then
            local okMix, finalBuf = pcall(function()
                local tmpChunkIn = sfxCacheDir .. "/_tmp_chunk_in.pcm"
                local fosIn = FileOutputStream(File(tmpChunkIn))
                fosIn.write(chunkVoiceBytes)
                fosIn.close()

                local fIn = io.open(tmpChunkIn, "rb")
                if not fIn then return smoothVoiceEdges(chunkVoiceBytes) end
                local chunkPcmStr = fIn:read("*a")
                fIn:close()

                local clauseSlices = sliceChunkPcmIntoClauses(chunkPcmStr, chunkClauses)
                local mixedSlices = {}
                for cIdx, cl in ipairs(chunkClauses) do
                    local sliceStr = clauseSlices[cIdx] or ""
                    local clausePaths = {}
                    for _, it in ipairs(cl.sfxItems or {}) do
                        local k = (type(it) == "table") and it.key or tostring(it)
                        local w = (type(it) == "table" and it.gainWeight) or 1.0
                        if keyPathMap[k] then
                            table.insert(clausePaths, { key = k, path = keyPathMap[k], gainWeight = w })
                        end
                    end
                    if #clausePaths > 0 and #sliceStr > 40 then
                        mixedSlices[cIdx] = mixClausePcmStringWithSfx(sliceStr, clausePaths, cl.text)
                    else
                        mixedSlices[cIdx] = sliceStr
                    end
                end

                local joinedPcm = table.concat(mixedSlices)
                local tmpChunkOut = sfxCacheDir .. "/_tmp_chunk_out.pcm"
                local fOut = io.open(tmpChunkOut, "wb")
                if not fOut then return smoothVoiceEdges(chunkVoiceBytes) end
                fOut:write(joinedPcm)
                fOut:close()

                local outFile = File(tmpChunkOut)
                local outLen = math.floor(tonumber(outFile.length()) or 0)
                local outBuf = byte[outLen]
                local fisOut = FileInputStream(outFile)
                fisOut.read(outBuf)
                fisOut.close()
                return smoothVoiceEdges(outBuf)
            end)
            if okMix and finalBuf then
                callback(finalBuf)
            else
                callback(smoothVoiceEdges(chunkVoiceBytes))
            end
            return
        end

        local key = neededKeys[kIdx]
        local localWav = sfxCacheDir .. "/" .. key .. ".wav"
        local pubWav = publicSfxDir .. "/" .. key .. ".wav"

        if File(localWav).exists() and File(localWav).length() > 500 then
            keyPathMap[key] = localWav
            kIdx = kIdx + 1
            ensureNextKey()
        elseif File(pubWav).exists() and File(pubWav).length() > 500 then
            keyPathMap[key] = pubWav
            kIdx = kIdx + 1
            ensureNextKey()
        else
            downloadSingleSfxOnline(key, QUERY_MAP[key] or (key:gsub("_", " ") .. " sound effect"), function()
                if File(localWav).exists() and File(localWav).length() > 500 then
                    keyPathMap[key] = localWav
                end
                kIdx = kIdx + 1
                ensureNextKey()
            end)
        end
    end

    ensureNextKey()
end

-- Mode 4: Audio with Sound Effects (Sequential API Failover + Pause/Resume Quota Guard + 54 Studio SFX)
function generateSfxStoryAudio(text, voice, apikey, model, generateBtn, playBtn, resultLayout)
    if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
    local trimmedText = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmedText == "" then showToast("Enter text"); isGenerating = false; return end
    if #apiKeys == 0 or getCurrentApiKey() == "" then showToast("API key missing"); isGenerating = false; return end

    resetApiFailoverState()
    ambientPhaseTracker = {}
    startProgressBar(15)
    ensureSfxPackExtracted()

    local sents = splitIntoSentences(trimmedText)
    local allClauses = {}
    local prevHadRain = false

    for _, s in ipairs(sents) do
        local sfxList = detectAllLocalSfxForSentence(s)
        local sfxItems = {}
        local seenKey = {}
        local hasRainNow = false
        local hasThunderNow = false

        for _, k in ipairs(sfxList) do
            if not BLOCKED_VOCAL_SFX[k] and k ~= "none" and not seenKey[k] then
                seenKey[k] = true
                table.insert(sfxItems, { key = k, gainWeight = 1.0 })
                if k == "rain" then hasRainNow = true end
                if k == "thunder" then hasThunderNow = true end
            end
        end

        if prevHadRain and hasThunderNow and not seenKey["rain"] then
            table.insert(sfxItems, 1, { key = "rain", gainWeight = 0.55 })
        end
        prevHadRain = hasRainNow

        table.insert(allClauses, {
            text = s,
            sfxItems = sfxItems
        })
    end

    local studioChunks = {}
    local curList = {}
    local curBytes = 0

    for _, cl in ipairs(allClauses) do
        local cLen = #cl.text
        if (#curList >= 4 or (curBytes + cLen > 950 and #curList > 0)) then
            table.insert(studioChunks, curList)
            curList = { cl }
            curBytes = cLen
        else
            table.insert(curList, cl)
            curBytes = curBytes + cLen + 1
        end
    end
    if #curList > 0 then
        table.insert(studioChunks, curList)
    end

    local allPcmParts = {}
    local idx = 1
    local lastErrorMsg = "Generation failed"

    local function finalizeSfxAudio(isPartial)
        if #allPcmParts == 0 then
            stopProgressBar()
            runOnUi(function()
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE SFX AUDIO") end
                showToast("Error: " .. tostring(lastErrorMsg))
                if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
            end)
            isGenerating = false
            return
        end

        local totalLen = 0
        for _, chunk in ipairs(allPcmParts) do totalLen = totalLen + #chunk end
        local tempPath = context.getCacheDir().getPath() .. "/sfx_story_" .. os.time() .. ".wav"
        local fos = FileOutputStream(File(tempPath))
        writeWavHeader(fos, totalLen, 24000, 1)
        for _, chunk in ipairs(allPcmParts) do fos.write(chunk) end
        fos.close()
        generatedAudioPath = tempPath

        finishProgressAndRun(function()
            if appHidden then
                appHidden = false
                hiddenGenerating = false
                showMainWithAudio()
            else
                if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                initMediaPlayer()
                pcall(function()
                    mediaPlayer.setDataSource(generatedAudioPath)
                    mediaPlayer.prepare()
                    applyPlaybackSpeed()
                end)
                if playBtn then playBtn.setEnabled(true); playBtn.setText("PLAY") end
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE SFX AUDIO") end
                showToast(isPartial and "Partial SFX Audio saved!" or "SFX Audio ready! 100%")
            end
            isGenerating = false
        end)
    end

    local function processNextStudioChunk()
        local totalChunks = #studioChunks
        if idx > totalChunks then
            finalizeSfxAudio(false)
            return
        end

        local chunkClauses = studioChunks[idx]
        local plainParts = {}
        for _, c in ipairs(chunkClauses) do table.insert(plainParts, c.text) end
        local plainChunkText = table.concat(plainParts, " ")
        local expressiveChunkPrompt = buildChunkExpressivePrompt(chunkClauses, selectedEmotion, false, voice)

        local minP = 10 + math.floor(((idx - 1) / totalChunks) * 85)
        local maxP = 10 + math.floor((idx / totalChunks) * 88)
        setProgressRange(minP, maxP)

        local attempts = 0
        local MAX_NON_QUOTA_ATTEMPTS = 4

        local function tryChunkVoice()
            attempts = attempts + 1
            local usePlainFallback = (attempts >= 3)
            fetchAudioSimple(plainChunkText, voice, getCurrentApiKey(), model, function(success, voiceBytes, errMsg, httpCode)
                if success and voiceBytes then
                    processStudioChunkWithSfx(voiceBytes, chunkClauses, function(mixedChunkBytes)
                        if mixedChunkBytes then
                            table.insert(allPcmParts, mixedChunkBytes)
                        end
                        idx = idx + 1
                        delay(800, processNextStudioChunk)
                    end)
                else
                    lastErrorMsg = errMsg or ("HTTP " .. tostring(httpCode))
                    markCurrentKeyDeadIfInvalid(httpCode, lastErrorMsg)

                    if httpCode == 400 or httpCode == 401 or httpCode == 403 or httpCode == 429 or httpCode == 503 then
                        if switchToNextValidApiKey() then
                            attempts = math.max(0, attempts - 1)
                            delay(900, tryChunkVoice)
                        else
                            -- ALL API keys exhausted/invalid -> pause safely, keep all generated audio, and let user wait or add a new API key!
                            showApiQuotaPausedDialog(idx - 1, totalChunks, lastErrorMsg, function()
                                attempts = 0
                                tryChunkVoice()
                            end, function()
                                finalizeSfxAudio(true)
                            end)
                        end
                    elseif attempts < MAX_NON_QUOTA_ATTEMPTS then
                        delay(2200, tryChunkVoice)
                    elseif #chunkClauses > 1 then
                        local mid = math.floor(#chunkClauses / 2)
                        local firstHalf = {}
                        local secondHalf = {}
                        for i = 1, mid do table.insert(firstHalf, chunkClauses[i]) end
                        for i = mid + 1, #chunkClauses do table.insert(secondHalf, chunkClauses[i]) end
                        studioChunks[idx] = firstHalf
                        table.insert(studioChunks, idx + 1, secondHalf)
                        delay(800, processNextStudioChunk)
                    else
                        showApiQuotaPausedDialog(idx - 1, totalChunks, lastErrorMsg, function()
                            attempts = 0
                            tryChunkVoice()
                        end, function()
                            finalizeSfxAudio(true)
                        end)
                    end
                end
            end, selectedEmotion, usePlainFallback, expressiveChunkPrompt)
        end

        tryChunkVoice()
    end

    processNextStudioChunk()
end

-- ===== PODCAST MODE V3 (PROFESSIONAL STUDIO CONVERSATION + MUTUAL ADDRESSING + GENDER-AWARE GRAMMAR + PAUSE/RESUME) =====
local function generateScriptForChunk(chunkText, apikey, callback, attempt, hostVoice, guestVoice, isFirstChunk, isLastChunk)
    attempt = attempt or 1
    local activeKey = cleanApiKey(getCurrentApiKey())
    local hostGender = getVoiceGenderLabel(hostVoice or selectedVoice or "Puck")
    local guestGender = getVoiceGenderLabel(guestVoice or selectedVoice2 or "Kore")

    local positionRule = ""
    if isFirstChunk and isLastChunk then
        positionRule = "- OPENING & CLOSING: Begin with a brief, warm professional podcast welcome to the listeners and greet your co-host/guest naturally, then dive straight into the topic. End the final 1-2 turns with a warm, natural podcast wrap-up thanking each other and the listeners."
    elseif isFirstChunk then
        positionRule = "- OPENING: Begin with a brief, warm professional podcast welcome to the listeners and greet your co-host/guest naturally, then dive straight into the topic. Do NOT conclude or say goodbye yet because the conversation continues in the next part."
    elseif isLastChunk then
        positionRule = "- CONTINUATION & CLOSING: Continue the ongoing podcast conversation seamlessly from the middle. STRICTLY FORBIDDEN to say 'آج ہم بات کرنے والے ہیں', 'خوش آمدید', 'welcome', or re-introduce the topic! Jump straight into the next point. End only the final 1-2 turns with a warm, natural podcast wrap-up thanking each other and the listeners."
    else
        positionRule = "- CONTINUATION: Continue the ongoing podcast conversation seamlessly right in the middle. STRICTLY FORBIDDEN to say 'آج ہم بات کرنے والے ہیں', 'خوش آمدید', 'welcome', or re-introduce the topic, and NO goodbye/outro yet."
    end

    local prompt = [[You are an award-winning professional podcast producer and scriptwriter. Transform the input text below into an authentic, engaging, studio-quality two-person podcast conversation between 'Host' (]] .. hostGender .. [[ voice) and 'Guest' (]] .. guestGender .. [[ voice).

CRITICAL CONVERSATION RULES:
1. TRUE MUTUAL ADDRESSING & CHEMISTRY: Host and Guest MUST directly address each other throughout the conversation instead of reading dry alternating sentences! They should react genuinely to what the other just said, agree, express curiosity or surprise, build on each other's points, and ask natural follow-up questions (for example in Urdu: "بالکل صحیح کہا آپ نے!", "اچھا یہ بتائیں کہ...", "واہ، بڑی دلچسپ بات ہے...", "جی بالکل، اور اس میں سب سے خاص بات یہ ہے کہ...", "آپ کا کیا خیال ہے؟", "سننے والوں کو یہ بھی بتاتے چلیں کہ..."; or natural equivalents in whatever language the input is written in).
2. STRICT GENDER-AWARE GRAMMAR:
   - Host is ]] .. hostGender .. [[ and Guest is ]] .. guestGender .. [[.
   - In Urdu/Hindi or any gendered language, Host MUST speak using ]] .. hostGender .. [[ self-grammar and address Guest using ]] .. guestGender .. [[ grammar, while Guest MUST speak using ]] .. guestGender .. [[ self-grammar and address Host using ]] .. hostGender .. [[ grammar! Never mix up masculine and feminine verb forms.
3. NATURAL FLOW & PACING:
   - Start with Host and alternate cleanly: Host, Guest, Host, Guest...
   - Keep each turn concise and punchy (1 to 3 natural spoken sentences) so it sounds like a real radio/YouTube podcast, never long robotic monologues.
   - ]] .. positionRule .. [[
4. COMPLETE FACT COVERAGE & LANGUAGE:
   - Keep the EXACT same language as the input text (e.g., natural conversational Urdu if input is Urdu, English if English).
   - Cover EVERY single sentence, match, score, player name, date, and detail from the input text in order. NEVER skip or summarize away any fact.
   - Do NOT invent random character names and do NOT use stiff formal titles like "مہمانِ خصوصی" mid-show; address each other warmly and naturally like real co-hosts ("آپ").
5. OUTPUT FORMAT:
   - Output ONLY a valid JSON array of objects, each with keys "speaker" ("Host" or "Guest") and "text".

Input text: ]] .. chunkText

    local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. activeKey
    local body = {
        contents = { { parts = { { text = prompt } } } },
        generationConfig = {
            temperature = 0.68,
            maxOutputTokens = 8192,
            responseMimeType = "application/json"
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({ run = function()
        if not completed then
            completed = true
            if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
            if attempt < 3 then
                delay(2000, function() generateScriptForChunk(chunkText, getCurrentApiKey(), callback, attempt + 1, hostVoice, guestVoice, isFirstChunk, isLastChunk) end)
            else
                callback(false, "Timeout")
            end
        end
    end })
    timeoutHandler.postDelayed(timeoutRunnable, 45000)

    currentHttpRequest = Http.post(url, cjson.encode(body), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
                    local raw = candidate.content.parts[1].text
                    if raw then
                        local cleaned = raw:gsub("```json\n?", ""):gsub("\n```", ""):gsub("```", "")
                        local s, e = cleaned:find("%[.*%]")
                        if s then cleaned = cleaned:sub(s, e) end
                        local okj, dialogue = pcall(cjson.decode, cleaned)
                        if okj and type(dialogue) == "table" and #dialogue > 0 then
                            callback(true, dialogue)
                            return
                        end
                    end
                end
            end
            if attempt < 3 then
                delay(1800, function() generateScriptForChunk(chunkText, getCurrentApiKey(), callback, attempt + 1, hostVoice, guestVoice, isFirstChunk, isLastChunk) end)
            else
                callback(false, "Invalid script")
            end
        else
            local errStr = extractApiError(code, content)
            markCurrentKeyDeadIfInvalid(code, errStr)
            if (code == 400 or code == 401 or code == 403 or code == 429 or code == 503) and switchToNextValidApiKey() then
                delay(1000, function() generateScriptForChunk(chunkText, getCurrentApiKey(), callback, attempt, hostVoice, guestVoice, isFirstChunk, isLastChunk) end)
            elseif attempt < 3 and code ~= 429 then
                delay(2200, function() generateScriptForChunk(chunkText, getCurrentApiKey(), callback, attempt + 1, hostVoice, guestVoice, isFirstChunk, isLastChunk) end)
            else
                callback(false, errStr, code)
            end
        end
    end)
end

-- Generates podcast audio by grouping 4-6 Host/Guest turns into ONE native multi-speaker TTS call
-- (4x fewer API calls + natural conversation flow), with automatic single-speaker fallback & Pause/Resume!
local function runPodcastAudioEngine(dialogue, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout, minPctBase, maxPctCeiling)
    -- Group dialogue turns into multi-speaker batches (~950 bytes, max 6 turns)
    local batches = {}
    local curBatch = {}
    local curBytes = 0
    for _, turn in ipairs(dialogue) do
        local tLen = #(tostring(turn.text or ""))
        if (#curBatch >= 6 or (curBytes + tLen > 950 and #curBatch > 0)) then
            table.insert(batches, curBatch)
            curBatch = { turn }
            curBytes = tLen
        else
            table.insert(curBatch, turn)
            curBytes = curBytes + tLen + 10
        end
    end
    if #curBatch > 0 then table.insert(batches, curBatch) end

    local allAudio = {}
    local batchIdx = 1
    local basePct = minPctBase or 25
    local ceilPct = maxPctCeiling or 98
    local lastErr = "Podcast generation failed"

    local function finalizePodcast(isPartial)
        if #allAudio == 0 then
            stopProgressBar()
            runOnUi(function()
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE PODCAST") end
                showToast("Error: " .. tostring(lastErr))
                if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
                isGenerating = false
            end)
            return
        end
        local totalLen = 0
        for _, chunk in ipairs(allAudio) do totalLen = totalLen + #chunk end
        local tempPath = context.getCacheDir().getPath() .. "/podcast_" .. os.time() .. ".wav"
        local fos = FileOutputStream(File(tempPath))
        writeWavHeader(fos, totalLen, 24000, 1)
        for _, chunk in ipairs(allAudio) do fos.write(chunk) end
        fos.close()
        generatedAudioPath = tempPath

        finishProgressAndRun(function()
            if appHidden then
                appHidden = false
                hiddenGenerating = false
                showMainWithAudio()
            else
                if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                initMediaPlayer()
                pcall(function()
                    mediaPlayer.setDataSource(generatedAudioPath)
                    mediaPlayer.prepare()
                    applyPlaybackSpeed()
                end)
                if playBtn then playBtn.setEnabled(true); playBtn.setText("PLAY") end
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE PODCAST") end
                showToast(isPartial and "Partial Podcast saved!" or "Podcast ready! 100%")
            end
            isGenerating = false
        end)
    end

    -- Fallback: speak a single batch turn-by-turn if multi-speaker ever returns 400
    local function speakBatchTurnByTurn(batchTurns, onBatchDone)
        local tIdx = 1
        local function nextTurn()
            if tIdx > #batchTurns then
                onBatchDone()
                return
            end
            local turn = batchTurns[tIdx]
            local spLow = (turn.speaker or ""):lower()
            local vName = (spLow == "guest") and guestVoice or hostVoice
            local tAttempts = 0
            local function tryTurn()
                tAttempts = tAttempts + 1
                fetchAudioSimple(turn.text, vName, getCurrentApiKey(), model, function(ok, audio, err, code)
                    if ok and audio then
                        table.insert(allAudio, smoothVoiceEdges(audio))
                        tIdx = tIdx + 1
                        delay(500, nextTurn)
                    else
                        lastErr = err or ("HTTP " .. tostring(code))
                        markCurrentKeyDeadIfInvalid(code, lastErr)
                        if (code == 400 or code == 401 or code == 403 or code == 429 or code == 503) and switchToNextValidApiKey() then
                            delay(900, tryTurn)
                        elseif tAttempts < 3 and code ~= 429 then
                            delay(2000, tryTurn)
                        else
                            showApiQuotaPausedDialog(batchIdx - 1, #batches, lastErr, function()
                                tAttempts = 0
                                tryTurn()
                            end, function()
                                finalizePodcast(true)
                            end)
                        end
                    end
                end, "Auto (Smart Emotion)")
            end
            tryTurn()
        end
        nextTurn()
    end

    local function processNextBatch()
        local totalBatches = #batches
        if batchIdx > totalBatches then
            finalizePodcast(false)
            return
        end

        local segStartPct = basePct + math.floor(((batchIdx - 1) / totalBatches) * (ceilPct - basePct))
        local segEndPct = basePct + math.floor((batchIdx / totalBatches) * (ceilPct - basePct))
        setProgressRange(segStartPct, segEndPct)

        local batchTurns = batches[batchIdx]
        local attempts = 0

        local function tryMultiSpeakerBatch()
            attempts = attempts + 1
            fetchMultiSpeakerPodcastAudio(batchTurns, hostVoice, guestVoice, getCurrentApiKey(), function(ok, audioBytes, errMsg, httpCode)
                if ok and audioBytes then
                    table.insert(allAudio, smoothVoiceEdges(audioBytes))
                    batchIdx = batchIdx + 1
                    delay(800, processNextBatch)
                else
                    lastErr = errMsg or ("HTTP " .. tostring(httpCode))
                    markCurrentKeyDeadIfInvalid(httpCode, lastErr)

                    -- If HTTP 400 is a schema/prompt issue (not API key invalid), fall back cleanly to turn-by-turn single-speaker!
                    if httpCode == 400 and not lastErr:lower():find("api_key_invalid") and not lastErr:lower():find("key not valid") then
                        speakBatchTurnByTurn(batchTurns, function()
                            batchIdx = batchIdx + 1
                            delay(600, processNextBatch)
                        end)
                        return
                    end

                    if httpCode == 400 or httpCode == 401 or httpCode == 403 or httpCode == 429 or httpCode == 503 then
                        if switchToNextValidApiKey() then
                            attempts = math.max(0, attempts - 1)
                            delay(900, tryMultiSpeakerBatch)
                        else
                            showApiQuotaPausedDialog(batchIdx - 1, totalBatches, lastErr, function()
                                attempts = 0
                                tryMultiSpeakerBatch()
                            end, function()
                                finalizePodcast(true)
                            end)
                        end
                    elseif attempts < 3 then
                        delay(2200, tryMultiSpeakerBatch)
                    else
                        speakBatchTurnByTurn(batchTurns, function()
                            batchIdx = batchIdx + 1
                            delay(600, processNextBatch)
                        end)
                    end
                end
            end)
        end

        tryMultiSpeakerBatch()
    end

    processNextBatch()
end

function generatePodcastDirect(originalText, apikey, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout)
    resetApiFailoverState()
    startProgressBar(15)
    local sentences = splitIntoSentences(originalText)
    local dialogue = {}
    for i, sent in ipairs(sentences) do
        local speaker = (i % 2 == 1) and "Host" or "Guest"
        table.insert(dialogue, {speaker = speaker, text = sent})
    end
    runPodcastAudioEngine(dialogue, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout, 10, 98)
end

function generatePodcast(userText, apikey, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout)
    resetApiFailoverState()
    startProgressBar(25)
    local chunks = splitTextIntoChunks(userText, 1800)
    local allDialogues = {}
    local currentChunkIdx = 1

    local function processNextChunk()
        if currentChunkIdx > #chunks then
            local finalDialogue = {}
            for _, d in ipairs(allDialogues) do
                for _, seg in ipairs(d) do table.insert(finalDialogue, seg) end
            end
            if #finalDialogue == 0 then
                runOnUi(function()
                    showToast("Using Direct Podcast mode")
                    generatePodcastDirect(userText, apikey, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout)
                end)
                return
            end
            runPodcastAudioEngine(finalDialogue, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout, 25, 98)
            return
        end

        local scriptMin = math.floor(((currentChunkIdx - 1) / #chunks) * 24) + 1
        local scriptMax = math.floor((currentChunkIdx / #chunks) * 25)
        setProgressRange(scriptMin, scriptMax)

        local isFirstChunk = (currentChunkIdx == 1)
        local isLastChunk = (currentChunkIdx == #chunks)
        generateScriptForChunk(chunks[currentChunkIdx], getCurrentApiKey(), function(success, dialogue, httpCode)
            if success and dialogue and #dialogue > 0 then
                table.insert(allDialogues, dialogue)
                currentChunkIdx = currentChunkIdx + 1
                delay(500, processNextChunk)
            elseif httpCode == 429 or httpCode == 401 or httpCode == 403 then
                showApiQuotaPausedDialog(currentChunkIdx - 1, #chunks, tostring(dialogue), function()
                    processNextChunk()
                end, function()
                    -- Convert remaining chunks directly into Host/Guest dialogue and proceed
                    for k = currentChunkIdx, #chunks do
                        local sentences = splitIntoSentences(chunks[k])
                        local fb = {}
                        for i, sent in ipairs(sentences) do
                            table.insert(fb, { speaker = (i % 2 == 1) and "Host" or "Guest", text = sent })
                        end
                        table.insert(allDialogues, fb)
                    end
                    currentChunkIdx = #chunks + 1
                    processNextChunk()
                end)
            else
                local sentences = splitIntoSentences(chunks[currentChunkIdx])
                local fallback = {}
                for i, sent in ipairs(sentences) do
                    local speaker = (i % 2 == 1) and "Host" or "Guest"
                    table.insert(fallback, {speaker = speaker, text = sent})
                end
                table.insert(allDialogues, fallback)
                currentChunkIdx = currentChunkIdx + 1
                delay(500, processNextChunk)
            end
        end, 1, hostVoice, guestVoice, isFirstChunk, isLastChunk)
    end

    processNextChunk()
end

-- ===== SINGLE VOICE AUDIO (SEQUENTIAL API FAILOVER + PAUSE/RESUME QUOTA GUARD + UNLIMITED TEXT) =====
function generateSingleAudio(text, voice, apikey, model, generateBtn, playBtn, resultLayout)
    if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
    local trimmedText = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmedText == "" then showToast("Enter text"); isGenerating = false; return end
    if #apiKeys == 0 or getCurrentApiKey() == "" then showToast("API key missing"); isGenerating = false; return end

    resetApiFailoverState()
    local chunks = splitTextIntoChunks(trimmedText, 1350)
    local allAudioChunks = {}
    local currentIdx = 1
    local lastErrorMsg = "Generation failed"

    startProgressBar(math.max(5, math.floor(94 / #chunks)))

    local function finalizeSingleAudio(isPartial)
        if #allAudioChunks == 0 then
            stopProgressBar()
            runOnUi(function()
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE AUDIO") end
                showToast("Error: " .. tostring(lastErrorMsg))
                if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
            end)
            isGenerating = false
            return
        end

        local totalLen = 0
        for _, bytes in ipairs(allAudioChunks) do totalLen = totalLen + #bytes end
        local tempPath = context.getCacheDir().getPath() .. "/tts_" .. os.time() .. ".wav"
        local fos = FileOutputStream(File(tempPath))
        writeWavHeader(fos, totalLen, 24000, 1)
        for _, bytes in ipairs(allAudioChunks) do fos.write(bytes) end
        fos.close()
        generatedAudioPath = tempPath

        finishProgressAndRun(function()
            if appHidden then
                appHidden = false
                hiddenGenerating = false
                showMainWithAudio()
            else
                if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                initMediaPlayer()
                pcall(function()
                    mediaPlayer.setDataSource(generatedAudioPath)
                    mediaPlayer.prepare()
                    applyPlaybackSpeed()
                end)
                if playBtn then playBtn.setEnabled(true); playBtn.setText("PLAY") end
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE AUDIO") end
                showToast(isPartial and "Partial Audio saved!" or "Audio ready! 100%")
            end
            isGenerating = false
        end)
    end

    local function processSingleChunk()
        local totalChunks = #chunks
        if currentIdx > totalChunks then
            finalizeSingleAudio(false)
            return
        end

        local startPct = math.floor(((currentIdx - 1) / totalChunks) * 94) + 1
        local endPct = math.floor((currentIdx / totalChunks) * 95)
        setProgressRange(startPct, endPct)

        local chunkText = chunks[currentIdx]
        local chunkSents = splitIntoSentences(chunkText)
        local chunkClauses = {}
        for _, s in ipairs(chunkSents) do table.insert(chunkClauses, { text = s }) end
        local expressivePrompt = buildChunkExpressivePrompt(chunkClauses, selectedEmotion, false)

        local attemptCount = 0
        local MAX_ATTEMPTS = 4

        local function tryChunkRequest()
            attemptCount = attemptCount + 1
            local usePlainFallback = (attemptCount >= 3)
            fetchAudioSimple(chunkText, voice, getCurrentApiKey(), model, function(success, audioBytes, errMsg, httpCode)
                if success and audioBytes then
                    table.insert(allAudioChunks, smoothVoiceEdges(audioBytes))
                    currentIdx = currentIdx + 1
                    delay(800, processSingleChunk)
                else
                    lastErrorMsg = errMsg or ("HTTP " .. tostring(httpCode))
                    markCurrentKeyDeadIfInvalid(httpCode, lastErrorMsg)

                    if httpCode == 400 or httpCode == 401 or httpCode == 403 or httpCode == 429 or httpCode == 503 then
                        if switchToNextValidApiKey() then
                            attemptCount = math.max(0, attemptCount - 1)
                            delay(900, tryChunkRequest)
                        else
                            showApiQuotaPausedDialog(currentIdx - 1, totalChunks, lastErrorMsg, function()
                                attemptCount = 0
                                tryChunkRequest()
                            end, function()
                                finalizeSingleAudio(true)
                            end)
                        end
                    elseif attemptCount < MAX_ATTEMPTS then
                        delay(2200, tryChunkRequest)
                    elseif #chunkSents > 1 then
                        local mid = math.floor(#chunkSents / 2)
                        local p1 = {}
                        local p2 = {}
                        for i = 1, mid do table.insert(p1, chunkSents[i]) end
                        for i = mid + 1, #chunkSents do table.insert(p2, chunkSents[i]) end
                        chunks[currentIdx] = table.concat(p1, " ")
                        table.insert(chunks, currentIdx + 1, table.concat(p2, " "))
                        delay(800, processSingleChunk)
                    else
                        showApiQuotaPausedDialog(currentIdx - 1, totalChunks, lastErrorMsg, function()
                            attemptCount = 0
                            tryChunkRequest()
                        end, function()
                            finalizeSingleAudio(true)
                        end)
                    end
                end
            end, selectedEmotion, usePlainFallback, expressivePrompt)
        end

        tryChunkRequest()
    end

    processSingleChunk()
end

-- ===== MUSIC MODE V2 (TIMEOUT PROTECTION + STRICT JSON + SMOOTH EDGES + SEQUENTIAL API FAILOVER + PAUSE/RESUME) =====
local SINGING_PROMPT = "Sing the following lyrics in a melodious, expressive singing voice: "

function getVoiceForGender(gender)
    return (gender == "male") and maleVoiceForMusic or femaleVoiceForMusic
end

function generateLyricsFromTheme(theme, userLyrics, apikey, callback)
    local prompt = "You are a songwriter. Generate meaningful song lyrics (max 180 words) based on: " .. theme
    if userLyrics and userLyrics ~= "" then prompt = prompt .. "\nUser lyrics: " .. userLyrics end
    prompt = prompt .. "\nOutput only raw lyrics, no extra text."
    local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. cleanApiKey(getCurrentApiKey())
    local body = { contents = { { parts = { { text = prompt } } } }, generationConfig = { temperature = 0.8 } }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({ run = function()
        if not completed then
            completed = true
            if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
            callback(nil, "Timeout (45s)", 408)
        end
    end })
    timeoutHandler.postDelayed(timeoutRunnable, 45000)

    currentHttpRequest = Http.post(url, cjson.encode(body), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
                    local lyrics = candidate.content.parts[1].text
                    if lyrics and lyrics ~= "" then callback(lyrics, nil, 200) return end
                end
            end
            callback(nil, "No lyrics", 200)
        else
            local errStr = extractApiError(code, content)
            markCurrentKeyDeadIfInvalid(code, errStr)
            if (code == 400 or code == 401 or code == 403 or code == 429 or code == 503) and switchToNextValidApiKey() then
                delay(900, function() generateLyricsFromTheme(theme, userLyrics, getCurrentApiKey(), callback) end)
            else
                callback(nil, errStr, code)
            end
        end
    end)
end

function generateSingingScript(lyrics, apikey, callback)
    local systemPrompt = [[Split the lyrics into a singing duet between male and female. Output ONLY a valid JSON array of objects with keys: "speaker" ("male" or "female"), "text" (short phrase max 120 chars), "voice" (Puck/Fenrir/Charon/Zephyr for male, Kore/Aoede/Callirrhoe/Leda for female). Lyrics: ]] .. lyrics
    local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. cleanApiKey(getCurrentApiKey())
    local body = {
        contents = { { parts = { { text = systemPrompt } } } },
        generationConfig = { temperature = 0.7, responseMimeType = "application/json" }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({ run = function()
        if not completed then
            completed = true
            if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
            callback(nil, "Timeout (45s)", 408)
        end
    end })
    timeoutHandler.postDelayed(timeoutRunnable, 45000)

    currentHttpRequest = Http.post(url, cjson.encode(body), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
                    local raw = candidate.content.parts[1].text
                    if raw then
                        local cleaned = raw:gsub("```json\n?", ""):gsub("\n```", ""):gsub("```", "")
                        local s, e = cleaned:find("%[.*%]")
                        if s then cleaned = cleaned:sub(s, e) end
                        local okj, dialogue = pcall(cjson.decode, cleaned)
                        if okj and type(dialogue) == "table" and #dialogue > 0 then
                            callback(dialogue, nil, 200) return
                        end
                    end
                end
            end
            callback(nil, "Invalid response", 200)
        else
            local errStr = extractApiError(code, content)
            markCurrentKeyDeadIfInvalid(code, errStr)
            if (code == 400 or code == 401 or code == 403 or code == 429 or code == 503) and switchToNextValidApiKey() then
                delay(900, function() generateSingingScript(lyrics, getCurrentApiKey(), callback) end)
            else
                callback(nil, errStr, code)
            end
        end
    end)
end

function generateSingingChunkWithRetry(text, voice, apikey, model, maxRetries, callback, attempt)
    attempt = attempt or 1
    local activeKey = cleanApiKey(getCurrentApiKey())
    local activeVoice = isValidVoice(voice) and voice or "Puck"
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. DEFAULT_TTS_MODEL .. ":generateContent?key=" .. activeKey
    local fullText = SINGING_PROMPT .. text
    local requestBody = {
        contents = { { parts = { { text = fullText } } } },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = { voiceConfig = { prebuiltVoiceConfig = { voiceName = activeVoice } } }
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({
        run = function()
            if not completed then
                completed = true
                if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
                if attempt < maxRetries then
                    delay(2000, function() generateSingingChunkWithRetry(text, voice, getCurrentApiKey(), model, maxRetries, callback, attempt + 1) end)
                else
                    callback(nil, "Timeout", 408)
                end
            end
        end
    })
    timeoutHandler.postDelayed(timeoutRunnable, 60000)

    currentHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts then
                    for _, part in ipairs(candidate.content.parts) do
                        if part.inlineData and part.inlineData.data then
                            local audioBytes = Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                            callback(audioBytes, nil, 200) return
                        end
                    end
                end
            end
            callback(nil, "No audio", 200)
        else
            local errStr = extractApiError(code, content)
            markCurrentKeyDeadIfInvalid(code, errStr)
            if (code == 400 or code == 401 or code == 403 or code == 429 or code == 503) and switchToNextValidApiKey() then
                delay(900, function() generateSingingChunkWithRetry(text, voice, getCurrentApiKey(), model, maxRetries, callback, attempt) end)
            elseif attempt < maxRetries and code ~= 429 then
                delay(2200, function() generateSingingChunkWithRetry(text, voice, getCurrentApiKey(), model, maxRetries, callback, attempt + 1) end)
            else
                callback(nil, errStr, code)
            end
        end
    end)
end

function mergeAudioChunks(chunksList, outputPath)
    local totalLen = 0
    for _, chunk in ipairs(chunksList) do totalLen = totalLen + #chunk end
    local fos = FileOutputStream(File(outputPath))
    writeWavHeader(fos, totalLen, 24000, 1)
    for _, chunk in ipairs(chunksList) do fos.write(chunk) end
    fos.close()
    return outputPath
end

function generateMusicFromDialogue(dialogue, style, apikey, model, generateBtn, playBtn, resultLayout)
    local total = #dialogue
    local allAudio = {}
    local current = 1

    local function finalizeMusic(isPartial)
        if #allAudio == 0 then
            stopProgressBar()
            runOnUi(function()
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                showToast("No audio chunks generated.")
                if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
                isGenerating = false
            end)
            return
        end
        local finalPath = context.getCacheDir().getPath() .. "/final_music_" .. os.time() .. ".wav"
        mergeAudioChunks(allAudio, finalPath)
        generatedAudioPath = finalPath
        finishProgressAndRun(function()
            if appHidden then
                appHidden = false
                hiddenGenerating = false
                showMainWithAudio()
            else
                if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                initMediaPlayer()
                pcall(function()
                    mediaPlayer.setDataSource(generatedAudioPath)
                    mediaPlayer.prepare()
                    applyPlaybackSpeed()
                    mediaPlayer.start()
                    isPlaying = true
                    if playBtn then playBtn.setText("PAUSE") end
                end)
                if playBtn then playBtn.setEnabled(true) end
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE MUSIC") end
                showToast(isPartial and "Partial Music saved!" or "Music ready! 100%")
            end
            isGenerating = false
        end)
    end

    local function processNext()
        if current > total then
            finalizeMusic(false)
            return
        end

        local seg = dialogue[current]
        local speaker = seg.speaker
        local lyric = seg.text
        local voice = seg.voice or getVoiceForGender(speaker)
        local startPct = 25 + math.floor(((current - 1) / total) * 72)
        local endPct = 25 + math.floor((current / total) * 73)
        setProgressRange(startPct, endPct)

        generateSingingChunkWithRetry(lyric, voice, getCurrentApiKey(), model, 3, function(audio, err, httpCode)
            if audio then
                table.insert(allAudio, smoothVoiceEdges(audio))
                current = current + 1
                delay(650, processNext)
            else
                showApiQuotaPausedDialog(current - 1, total, tostring(err), function()
                    processNext()
                end, function()
                    finalizeMusic(true)
                end)
            end
        end)
    end
    processNext()
end

function generateMusicWithTheme(theme, userLyrics, style, apikey, model, generateBtn, playBtn, resultLayout)
    resetApiFailoverState()
    if userLyrics and userLyrics ~= "" then
        startProgressBar(25)
        local function runScript()
            generateSingingScript(userLyrics, getCurrentApiKey(), function(dialogue, err, code)
                if err or not dialogue then
                    if code == 429 or code == 401 or code == 403 then
                        showApiQuotaPausedDialog(0, 1, tostring(err), runScript, function()
                            stopProgressBar()
                            runOnUi(function()
                                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                            end)
                            isGenerating = false
                        end)
                        return
                    end
                    stopProgressBar()
                    runOnUi(function()
                        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                        showToast("Script failed: " .. tostring(err))
                        if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
                    end)
                    isGenerating = false
                    return
                end
                generateMusicFromDialogue(dialogue, style, getCurrentApiKey(), model, generateBtn, playBtn, resultLayout)
            end)
        end
        runScript()
    elseif theme and theme ~= "" then
        startProgressBar(15)
        local function runLyrics()
            generateLyricsFromTheme(theme, "", getCurrentApiKey(), function(lyrics, err, code)
                if err or not lyrics then
                    if code == 429 or code == 401 or code == 403 then
                        showApiQuotaPausedDialog(0, 1, tostring(err), runLyrics, function()
                            stopProgressBar()
                            runOnUi(function()
                                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                            end)
                            isGenerating = false
                        end)
                        return
                    end
                    stopProgressBar()
                    runOnUi(function()
                        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                        showToast("Lyrics failed: " .. tostring(err))
                        if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
                    end)
                    isGenerating = false
                    return
                end
                setProgressRange(15, 28)
                local function runThemeScript()
                    generateSingingScript(lyrics, getCurrentApiKey(), function(dialogue, err2, code2)
                        if err2 or not dialogue then
                            if code2 == 429 or code2 == 401 or code2 == 403 then
                                showApiQuotaPausedDialog(0, 1, tostring(err2), runThemeScript, function()
                                    stopProgressBar()
                                    runOnUi(function()
                                        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                                    end)
                                    isGenerating = false
                                end)
                                return
                            end
                            stopProgressBar()
                            runOnUi(function()
                                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("GENERATE MUSIC") end
                                showToast("Script failed: " .. tostring(err2))
                                if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
                            end)
                            isGenerating = false
                            return
                        end
                        generateMusicFromDialogue(dialogue, style, getCurrentApiKey(), model, generateBtn, playBtn, resultLayout)
                    end)
                end
                runThemeScript()
            end)
        end
        runLyrics()
    else
        stopProgressBar()
        runOnUi(function()
            if generateBtn then generateBtn.setEnabled(true) end
            showToast("Enter theme or lyrics")
            if appHidden then appHidden = false; hiddenGenerating = false; showMain() end
        end)
        isGenerating = false
    end
end

-- ===== API SETTINGS (DISTINCT CYBER SAPPHIRE & GOLD VAULT WINDOW) =====

-- ===== MODE 5: AUDIO TO SOUND EFFECTS (MOBILE AUDIO PICKER + GEMINI TIMESTAMP ANALYZER + STUDIO MIXER) =====
local function formatDurationMs(ms)
    local totalSec = math.max(0, math.floor((tonumber(ms) or 0) / 1000))
    local m = math.floor(totalSec / 60)
    local s = totalSec % 60
    return string.format("%02d:%02d", m, s)
end

local function scanDeviceAudioFiles()
    local results = {}
    local seenKeys = {}

    local function addAudioItem(p, uriObj, n, d)
        local key = (p and p ~= "") and p or (uriObj and tostring(uriObj) or "")
        if key == "" or seenKeys[key] then return end
        seenKeys[key] = true
        local displayName = (n and n ~= "") and tostring(n) or nil
        if not displayName and p and p ~= "" then
            displayName = tostring(p):match("([^/]+)$") or p
        end
        displayName = displayName or "Audio File"
        table.insert(results, {
            path = p or "",
            uri = uriObj,
            name = displayName,
            lowerName = displayName:lower(),
            durationMs = tonumber(d) or 0
        })
    end

    -- 1. Primary: Android MediaStore.Audio.Media (ALL audio files on device with Content URI for Android 10-15 Scoped Storage!)
    pcall(function()
        local cr = context.getContentResolver()
        local baseUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        local proj = String({ "_id", "_data", "_display_name", "title", "duration" })
        local cursor = cr.query(baseUri, proj, nil, nil, "date_added DESC")
        if cursor ~= nil then
            local idxId = cursor.getColumnIndex("_id")
            local idxData = cursor.getColumnIndex("_data")
            local idxDisp = cursor.getColumnIndex("_display_name")
            local idxTitle = cursor.getColumnIndex("title")
            local idxDur = cursor.getColumnIndex("duration")
            while cursor.moveToNext() do
                local rowId = (idxId >= 0) and cursor.getLong(idxId) or -1
                local p = (idxData >= 0) and cursor.getString(idxData) or ""
                local disp = (idxDisp >= 0) and cursor.getString(idxDisp) or ""
                local ttl = (idxTitle >= 0) and cursor.getString(idxTitle) or ""
                local dur = (idxDur >= 0) and cursor.getLong(idxDur) or 0
                local itemUri = (rowId >= 0) and Uri.withAppendedPath(baseUri, tostring(rowId)) or nil
                -- Include ALL audio files (skip only our internal SFX cache folder)
                local isInternalSfx = p and (p:find("AudioCraft_SFX", 1, true) or p:find("sfx_wav_v", 1, true))
                if not isInternalSfx and (itemUri ~= nil or (p and p ~= "")) then
                    local bestName = (disp ~= "" and disp) or (ttl ~= "" and ttl) or (p:match("([^/]+)$") or ("Audio_" .. tostring(rowId)))
                    addAudioItem(p, itemUri, bestName, dur)
                end
            end
            cursor.close()
        end
    end)

    -- 2. Always ALSO scan common storage folders (catches Downloads, WhatsApp, Recordings, Music, Telegram, & app downloads!)
    local audioExts = { [".mp3"] = true, [".wav"] = true, [".m4a"] = true, [".aac"] = true, [".ogg"] = true, [".opus"] = true, [".flac"] = true, [".3gp"] = true, [".amr"] = true }
    local function scanFolder(dirPath, depth)
        if depth > 3 then return end
        pcall(function()
            local dir = File(dirPath)
            if not dir.exists() or not dir.isDirectory() then return end
            local files = dir.listFiles()
            if not files then return end
            for i = 0, #files - 1 do
                local f = files[i]
                if f then
                    if f.isDirectory() then
                        local dn = tostring(f.getName() or "")
                        if dn ~= "" and not dn:find("^%.") and not dn:find("AudioCraft_SFX", 1, true) and not dn:find("sfx_wav_v", 1, true) then
                            scanFolder(f.getAbsolutePath(), depth + 1)
                        end
                    else
                        local fn = tostring(f.getName() or "")
                        local ext = fn:lower():match("(%.[^%.]+)$")
                        if ext and audioExts[ext] and f.length() >= 1024 then
                            local fp = f.getAbsolutePath()
                            addAudioItem(fp, Uri.fromFile(f), fn, 0)
                        end
                    end
                end
            end
        end)
    end

    local dirs = {
        "/storage/emulated/0/Download",
        "/storage/emulated/0/Music",
        "/storage/emulated/0/Recordings",
        "/storage/emulated/0/Sounds",
        "/storage/emulated/0/Audiobooks",
        "/storage/emulated/0/Podcasts",
        "/storage/emulated/0/Documents",
        "/storage/emulated/0/WhatsApp/Media/WhatsApp Audio",
        "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio",
        "/storage/emulated/0/Telegram/Telegram Audio"
    }
    pcall(function()
        local appDl = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
        if appDl then table.insert(dirs, appDl.getAbsolutePath()) end
    end)
    for _, d in ipairs(dirs) do scanFolder(d, 0) end

    return results
end

local isAudioPickerOpen = false

function showMobileAudioPickerDialog(onAudioSelected)
    if isAudioPickerOpen then return end
    isAudioPickerOpen = true

    local allAudios = {}
    local totalCount = 0

    local pickerPlayer = nil
    local activePlayKey = nil
    local activePlayBtn = nil
    local currentPageLimit = 50
    local currentQuery = ""

    local function stopPickerPreview()
        if pickerPlayer ~= nil then
            pcall(function()
                if pickerPlayer.isPlaying() then pickerPlayer.stop() end
                pickerPlayer.release()
            end)
            pickerPlayer = nil
        end
        if activePlayBtn ~= nil then
            pcall(function()
                activePlayBtn.setText("PLAY")
                activePlayBtn.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 14, "#A9DFBF", 1))
            end)
        end
        activePlayKey = nil
        activePlayBtn = nil
    end

    local pViews = {}
    local pLayout = {
        LinearLayout, orientation = "vertical", padding = "18dp", layout_width = "fill", layout_height = "wrap", id = "pickerCard",
        {
            LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", id = "pickerHeaderBox", padding = "12dp", layout_marginBottom = "12dp", gravity = "center_vertical",
            {
                LinearLayout, orientation = "vertical", layout_width = "0dp", layout_weight = "1", layout_height = "wrap",
                { TextView, text = "Select Audio", textSize = 18, textColor = "#D980FA", typeface = Typeface.DEFAULT_BOLD },
                { TextView, id = "pickerCountText", text = "Scanning mobile audios...", textSize = 13, textColor = "#00E5FF", paddingTop = "2dp" }
            },
            { Button, id = "toggleSearchBtn", text = "SEARCH", layout_width = "wrap", layout_height = "wrap", textColor = "#FFFFFF", paddingLeft = "14dp", paddingRight = "14dp", paddingTop = "10dp", paddingBottom = "10dp", textSize = 13, typeface = Typeface.DEFAULT_BOLD }
        },
        {
            LinearLayout, id = "pickerSearchBox", orientation = "horizontal", layout_width = "fill", layout_height = "wrap", padding = "8dp", layout_marginBottom = "10dp", visibility = View.GONE,
            { EditText, id = "pickerSearchInput", hint = "Search audio by name...", layout_width = "0dp", layout_weight = "1", layout_height = "wrap", singleLine = true, padding = "10dp", textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF", backgroundColor = "#00000000" },
            { Button, id = "clearSearchBtn", text = "CLEAR", layout_width = "wrap", layout_height = "wrap", textColor = "#FFFFFF", paddingLeft = "12dp", paddingRight = "12dp", paddingTop = "8dp", paddingBottom = "8dp", textSize = 12, typeface = Typeface.DEFAULT_BOLD, layout_marginLeft = "6dp" }
        },
        {
            ScrollView, layout_width = "fill", layout_height = "380dp", id = "pickerScrollView",
            { LinearLayout, id = "pickerListContainer", orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "2dp" }
        },
        { Button, id = "closePickerBtn", text = "CLOSE", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "13dp", layout_marginTop = "12dp", textSize = 14, typeface = Typeface.DEFAULT_BOLD }
    }

    local dlg = LuaDialog(context)
    dlg.setCancelable(true)
    dlg.setView(loadlayout(pLayout, pViews))
    dlg.setOnDismissListener({ onDismiss = function() isAudioPickerOpen = false; stopPickerPreview() end })

    pcall(function()
        pViews.pickerCard.setBackground(createGradientDrawable("#100820", "#1E0F38", 24, "#D980FA", 3))
        pViews.pickerHeaderBox.setBackground(createCardDrawable("#1A0D33", 16, "#D980FA", 2))
        pViews.toggleSearchBtn.setBackground(createGradientDrawable("#00B4DB", "#0083B0", 16, "#80FFDB", 1))
        pViews.pickerSearchBox.setBackground(createCardDrawable("#150B29", 14, "#00E5FF", 2))
        pViews.clearSearchBtn.setBackground(createGradientDrawable("#576574", "#222F3E", 14, "#8395A7", 1))
        pViews.closePickerBtn.setBackground(createGradientDrawable("#636E72", "#2D3436", 18, "#B2BEC3", 1))
        pViews.pickerSearchInput.setImeOptions(EditorInfo.IME_ACTION_SEARCH)
        pViews.pickerSearchInput.setInputType(InputType.TYPE_CLASS_TEXT)
    end)

    local function playItemPreview(item, btnView)
        local itemKey = (item.uri and tostring(item.uri)) or item.path
        if activePlayKey == itemKey and pickerPlayer ~= nil then
            local okCheck, playingNow = pcall(function() return pickerPlayer.isPlaying() end)
            if okCheck and playingNow then
                pcall(function() pickerPlayer.pause() end)
                btnView.setText("PLAY")
                pcall(function() btnView.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 14, "#A9DFBF", 1)) end)
            else
                pcall(function() pickerPlayer.start() end)
                btnView.setText("PAUSE")
                pcall(function() btnView.setBackground(createGradientDrawable("#E67E22", "#D35400", 14, "#FDEBD0", 1)) end)
            end
            return
        end

        stopPickerPreview()

        local function tryPrepareSource(mp)
            -- 1. Prefer Android Content URI (works on Android 10-15 Scoped Storage!)
            if item.uri ~= nil then
                local okUri = pcall(function()
                    mp.setDataSource(context, item.uri)
                    mp.prepare()
                end)
                if okUri then return true end
                pcall(function() mp.reset() end)
            end
            -- 2. Fallback: FileDescriptor via ContentResolver
            if item.uri ~= nil then
                local okPfd = pcall(function()
                    local pfd = context.getContentResolver().openFileDescriptor(item.uri, "r")
                    if pfd then
                        mp.setDataSource(pfd.getFileDescriptor())
                        mp.prepare()
                        pfd.close()
                    else
                        error("no pfd")
                    end
                end)
                if okPfd then return true end
                pcall(function() mp.reset() end)
            end
            -- 3. Fallback: Direct file path via FileInputStream FD
            if item.path and item.path ~= "" then
                local okPath = pcall(function()
                    local fis = FileInputStream(File(item.path))
                    mp.setDataSource(fis.getFD())
                    mp.prepare()
                    fis.close()
                end)
                if okPath then return true end
                pcall(function() mp.reset() end)
                local okStr = pcall(function()
                    mp.setDataSource(item.path)
                    mp.prepare()
                end)
                if okStr then return true end
            end
            return false
        end

        local mp = MediaPlayer()
        if tryPrepareSource(mp) then
            pickerPlayer = mp
            mp.setOnCompletionListener({
                onCompletion = function()
                    runOnUi(function()
                        if activePlayBtn == btnView then
                            btnView.setText("PLAY")
                            pcall(function() btnView.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 14, "#A9DFBF", 1)) end)
                        end
                    end)
                end
            })
            mp.start()
            activePlayKey = itemKey
            activePlayBtn = btnView
            btnView.setText("PAUSE")
            pcall(function() btnView.setBackground(createGradientDrawable("#E67E22", "#D35400", 14, "#FDEBD0", 1)) end)
        else
            pcall(function() mp.release() end)
            showToast("Cannot play this audio file")
        end
    end

    local function renderAudioRows(queryStr, keepLimit)
        currentQuery = tostring(queryStr or "")
        if not keepLimit then currentPageLimit = 50 end
        pViews.pickerListContainer.removeAllViews()
        local q = currentQuery:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        local matched = {}
        for _, item in ipairs(allAudios) do
            if q == "" or item.lowerName:find(q, 1, true) then
                table.insert(matched, item)
            end
        end

        if q == "" then
            pViews.pickerCountText.setText("Total Audios: " .. tostring(totalCount))
        else
            pViews.pickerCountText.setText("Found: " .. tostring(#matched) .. " / " .. tostring(totalCount))
        end

        if #matched == 0 then
            local emptyViews = {}
            local emptyLayout = {
                TextView, text = (totalCount == 0) and "No audio files found on device storage." or "No matching audio found.", textSize = 14, textColor = "#CCCCCC", gravity = "center", padding = "28dp", layout_width = "fill", layout_height = "wrap"
            }
            pViews.pickerListContainer.addView(loadlayout(emptyLayout, emptyViews))
            return
        end

        local maxShow = math.min(#matched, currentPageLimit)
        for i = 1, maxShow do
            local item = matched[i]
            local itemKey = (item.uri and tostring(item.uri)) or item.path
            local rViews = {}
            local durLabel = (item.durationMs > 0) and (" (" .. formatDurationMs(item.durationMs) .. ")") or ""
            local isCurrentlyPlaying = (activePlayKey == itemKey and pickerPlayer ~= nil)
            local rLayout = {
                LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", paddingBottom = "8dp",
                {
                    LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", id = "rowCard", padding = "10dp", gravity = "center_vertical",
                    {
                        LinearLayout, id = "rowSelectArea", orientation = "vertical", layout_width = "0dp", layout_weight = "1", layout_height = "wrap", paddingRight = "8dp",
                        { TextView, id = "rowTitle", text = item.name, textSize = 14, textColor = "#FFFFFF", typeface = Typeface.DEFAULT_BOLD },
                        { TextView, id = "rowSub", text = (durLabel ~= "" and ("Duration:" .. durLabel) or "Tap to select audio"), textSize = 11, textColor = "#B8A9D9", paddingTop = "2dp" }
                    },
                    { Button, id = "rowPlayBtn", text = isCurrentlyPlaying and "PAUSE" or "PLAY", layout_width = "wrap", layout_height = "wrap", textColor = "#FFFFFF", paddingLeft = "14dp", paddingRight = "14dp", paddingTop = "9dp", paddingBottom = "9dp", textSize = 12, typeface = Typeface.DEFAULT_BOLD }
                }
            }
            local rowView = loadlayout(rLayout, rViews)
            pcall(function()
                rViews.rowCard.setBackground(createCardDrawable("#1A1032", 14, "#7158E2", 1))
                if isCurrentlyPlaying then
                    rViews.rowPlayBtn.setBackground(createGradientDrawable("#E67E22", "#D35400", 14, "#FDEBD0", 1))
                    activePlayBtn = rViews.rowPlayBtn
                else
                    rViews.rowPlayBtn.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 14, "#A9DFBF", 1))
                end
            end)

            rViews.rowSelectArea.onClick = function()
                vibrate(30)
                stopPickerPreview()
                selectedInputAudioPath = item.path
                selectedInputAudioUri = item.uri
                selectedInputAudioName = item.name
                selectedInputAudioDurMs = item.durationMs
                dlg.dismiss()
                if onAudioSelected then onAudioSelected(item) end
            end

            rViews.rowPlayBtn.onClick = function()
                vibrate(25)
                playItemPreview(item, rViews.rowPlayBtn)
            end

            pViews.pickerListContainer.addView(rowView)
        end

        if #matched > maxShow then
            local mViews = {}
            local mLayout = {
                LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", paddingTop = "6dp", paddingBottom = "6dp",
                { Button, id = "loadMoreAudiosBtn", text = "LOAD MORE (" .. tostring(maxShow) .. " / " .. tostring(#matched) .. ")", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "12dp", textSize = 13, typeface = Typeface.DEFAULT_BOLD }
            }
            local moreRow = loadlayout(mLayout, mViews)
            pcall(function()
                mViews.loadMoreAudiosBtn.setBackground(createGradientDrawable("#8E44AD", "#6C3483", 16, "#D980FA", 1))
            end)
            mViews.loadMoreAudiosBtn.onClick = function()
                vibrate(25)
                currentPageLimit = currentPageLimit + 50
                renderAudioRows(currentQuery, true)
            end
            pViews.pickerListContainer.addView(moreRow)
        end
    end

    pViews.toggleSearchBtn.onClick = function()
        vibrate(25)
        if pViews.pickerSearchBox.getVisibility() == View.VISIBLE then
            pViews.pickerSearchBox.setVisibility(View.GONE)
            pViews.pickerSearchInput.setText("")
            renderAudioRows("", false)
        else
            pViews.pickerSearchBox.setVisibility(View.VISIBLE)
            pcall(function()
                pViews.pickerSearchInput.requestFocus()
                local imm = context.getSystemService(Context.INPUT_METHOD_SERVICE)
                if imm then imm.showSoftInput(pViews.pickerSearchInput, InputMethodManager.SHOW_IMPLICIT) end
            end)
        end
    end

    pViews.clearSearchBtn.onClick = function()
        vibrate(20)
        pViews.pickerSearchInput.setText("")
        renderAudioRows("", false)
    end

    pViews.pickerSearchInput.addTextChangedListener({
        afterTextChanged = function(e)
            renderAudioRows(e.toString(), false)
        end
    })

    pcall(function()
        pViews.pickerSearchInput.setOnEditorActionListener({
            onEditorAction = function(v, actionId, event)
                if actionId == EditorInfo.IME_ACTION_SEARCH or actionId == EditorInfo.IME_ACTION_DONE then
                    renderAudioRows(v.getText().toString(), false)
                    pcall(function()
                        local imm = context.getSystemService(Context.INPUT_METHOD_SERVICE)
                        if imm then imm.hideSoftInputFromWindow(v.getWindowToken(), 0) end
                    end)
                    return true
                end
                return false
            end
        })
    end)

    pViews.closePickerBtn.onClick = function()
        vibrate(25)
        stopPickerPreview()
        dlg.dismiss()
    end

    local loadingViews = {}
    local loadingLayout = {
        TextView, text = "Loading audio files, please wait...", textSize = 14, textColor = "#00E5FF", gravity = "center", padding = "28dp", layout_width = "fill", layout_height = "wrap"
    }
    pViews.pickerListContainer.addView(loadlayout(loadingLayout, loadingViews))
    dlg.show()

    delay(60, function()
        if not isAudioPickerOpen then return end
        allAudios = scanDeviceAudioFiles()
        totalCount = #allAudios
        renderAudioRows(currentQuery, false)
    end)
end

-- Copy Content URI or file path to local cache if needed (guarantees Android 10-15 Scoped Storage access!)
local function stageUserAudioToCache(inputPath, inputUri)
    if inputPath and inputPath ~= "" then
        local f = io.open(inputPath, "rb")
        if f then f:close(); return inputPath, false end
    end
    if inputUri ~= nil then
        local ext = ".audio"
        if inputPath and inputPath ~= "" then
            local e = inputPath:lower():match("(%.[^%.]+)$")
            if e then ext = e end
        end
        local tmpPath = context.getCacheDir().getPath() .. "/staged_input_" .. os.time() .. ext
        local okCopy = pcall(function()
            local ins = context.getContentResolver().openInputStream(inputUri)
            if not ins then error("cannot open uri") end
            local fos = FileOutputStream(File(tmpPath))
            local buf = byte[16384]
            while true do
                local n = ins.read(buf)
                if n <= 0 then break end
                fos.write(buf, 0, n)
            end
            fos.close()
            ins.close()
        end)
        if okCopy and File(tmpPath).exists() and File(tmpPath).length() > 128 then
            return tmpPath, true
        end
    end
    return inputPath, false
end

-- Decode ANY user mobile audio (WAV, MP3, M4A, OGG, AAC, FLAC) of ANY LENGTH (25+ min, up to 2 hours!)
-- Streams 24000 Hz Mono 16-bit PCM directly to a disk file (under 3MB RAM, ZERO 10-min cutoff, ZERO Jieshuo hang!)
local function decodeFullUserAudioTo24kDiskAsync(inputPath, inputUri, onDone)
    local stagedPath, isTemp = stageUserAudioToCache(inputPath, inputUri)
    if not stagedPath or stagedPath == "" or not File(stagedPath).exists() or File(stagedPath).length() < 128 then
        onDone(nil, 0, "File not accessible")
        return
    end

    local outPcmPath = context.getCacheDir().getPath() .. "/user_24k_" .. os.time() .. ".pcm"
    pcall(function() File(outPcmPath).delete() end)

    local function resampleRawFileTo24kDisk(rawFilePath, rawDataOffset, rawDataBytes, srcRate, srcCh, deleteRawAfter)
        if isTemp then pcall(function() File(stagedPath).delete() end) end
        if not rawDataBytes or rawDataBytes < 400 then
            if deleteRawAfter then pcall(function() File(rawFilePath).delete() end) end
            onDone(nil, 0, "Could not decode audio file")
            return
        end

        local frameSize = srcCh * 2
        local srcFrames = math.floor(rawDataBytes / frameSize)
        local outFrames = math.floor(srcFrames * (24000 / srcRate))

        -- Fast streaming copy if already 24000 Hz Mono!
        if srcRate == 24000 and srcCh == 1 then
            local inF = io.open(rawFilePath, "rb")
            local outF = io.open(outPcmPath, "wb")
            if not inF or not outF then
                if inF then inF:close() end
                if outF then outF:close() end
                if deleteRawAfter then pcall(function() File(rawFilePath).delete() end) end
                onDone(nil, 0, "Disk write error")
                return
            end
            inF:seek("set", rawDataOffset)
            local copied = 0
            local function copyNextBlock()
                local want = math.min(262144, rawDataBytes - copied)
                if want <= 0 then
                    inF:close(); outF:close()
                    if deleteRawAfter then pcall(function() File(rawFilePath).delete() end) end
                    onDone(outPcmPath, outFrames, nil)
                    return
                end
                local buf = inF:read(want)
                if buf and #buf > 0 then
                    outF:write(buf)
                    copied = copied + #buf
                    delay(8, copyNextBlock)
                else
                    inF:close(); outF:close()
                    if deleteRawAfter then pcall(function() File(rawFilePath).delete() end) end
                    onDone(outPcmPath, math.floor(copied / 2), nil)
                end
            end
            delay(8, copyNextBlock)
            return
        end

        -- Cooperative disk-to-disk sliced resampling (24,000 output frames = 1s per tick -> ~15ms per tick, unlimited length!)
        local inF = io.open(rawFilePath, "rb")
        local outF = io.open(outPcmPath, "wb")
        if not inF or not outF then
            if inF then inF:close() end
            if outF then outF:close() end
            if deleteRawAfter then pcall(function() File(rawFilePath).delete() end) end
            onDone(nil, 0, "Disk write error")
            return
        end

        local ratio = srcRate / 24000.0
        local sByte = string.byte
        local sChar = string.char
        local floor = math.floor
        local curOutFrame = 0
        local SLICE_OUT = 24000

        local function resampleNextDiskSlice()
            local endOutFrame = math.min(outFrames, curOutFrame + SLICE_OUT)
            local startSrcF = floor(curOutFrame * ratio)
            local endSrcF = math.min(srcFrames - 1, floor((endOutFrame - 1) * ratio) + 1)
            local readByteStart = rawDataOffset + startSrcF * frameSize
            local readByteLen = (endSrcF - startSrcF + 1) * frameSize

            inF:seek("set", readByteStart)
            local srcChunk = inF:read(readByteLen) or ""
            local srcChunkFrames = floor(#srcChunk / frameSize)

            local parts = {}
            local pIdx = 0
            local blk = {}
            local bCnt = 0

            for i = curOutFrame, endOutFrame - 1 do
                local localSf = floor(i * ratio) - startSrcF
                if localSf < 0 then localSf = 0
                elseif localSf >= srcChunkFrames then localSf = srcChunkFrames - 1 end
                local pos = localSf * frameSize + 1
                local lo, hi = sByte(srcChunk, pos, pos + 1)
                local v = 0
                if lo and hi then
                    v = hi * 256 + lo
                    if v >= 32768 then v = v - 65536 end
                    if srcCh >= 2 then
                        local lo2, hi2 = sByte(srcChunk, pos + 2, pos + 3)
                        if lo2 and hi2 then
                            local v2 = hi2 * 256 + lo2
                            if v2 >= 32768 then v2 = v2 - 65536 end
                            v = floor((v + v2) * 0.5)
                        end
                    end
                end
                if v < 0 then v = v + 65536 end
                bCnt = bCnt + 1
                blk[bCnt] = sChar(v % 256, floor(v / 256) % 256)
                if bCnt >= 4096 then
                    pIdx = pIdx + 1
                    parts[pIdx] = table.concat(blk)
                    blk = {}; bCnt = 0
                end
            end
            if bCnt > 0 then pIdx = pIdx + 1; parts[pIdx] = table.concat(blk) end
            outF:write(table.concat(parts))

            curOutFrame = endOutFrame
            if curOutFrame < outFrames then
                delay(10, resampleNextDiskSlice)
            else
                inF:close(); outF:close()
                if deleteRawAfter then pcall(function() File(rawFilePath).delete() end) end
                onDone(outPcmPath, outFrames, nil)
            end
        end

        delay(10, resampleNextDiskSlice)
    end

    -- 1. Fast disk-header path if already a standard PCM WAV file (handles 25-min+ WAV without loading whole file into RAM!)
    local f = io.open(stagedPath, "rb")
    if f then
        local hdr = f:read(256)
        local fileLen = tonumber(File(stagedPath).length()) or 0
        f:close()
        if hdr and #hdr >= 44 and hdr:sub(1, 4) == "RIFF" and hdr:sub(9, 12) == "WAVE" then
            local sByte = string.byte
            local b23, b24 = sByte(hdr, 23, 24)
            local ch = (b23 or 1) + (b24 or 0) * 256
            if ch < 1 or ch > 2 then ch = 1 end
            local b25, b26, b27, b28 = sByte(hdr, 25, 28)
            local sr = (b25 or 0) + (b26 or 0) * 256 + (b27 or 0) * 65536 + (b28 or 0) * 16777216
            if sr < 4000 or sr > 96000 then sr = 24000 end
            local dPos = hdr:find("data", 13, true)
            local dataOff = dPos and (dPos + 7) or 44
            local dataBytes = math.max(0, fileLen - dataOff)
            if dataBytes > 400 then
                delay(12, function() resampleRawFileTo24kDisk(stagedPath, dataOff, dataBytes, sr, ch, false) end)
                return
            end
        end
    end

    -- 2. Cooperative NON-BLOCKING Android MediaExtractor + MediaCodec for MP3 / M4A / OGG / AAC / etc. (up to 2 hours!)
    local tmpRaw = context.getCacheDir().getPath() .. "/user_decode_" .. os.time() .. ".raw"
    local srcRate = 24000
    local srcCh = 1
    local extractor = nil
    local codec = nil
    local fos = nil
    local fc = nil
    local info = nil
    local inputEOS = false
    local outputEOS = false
    local maxPtsUs = 7200 * 1000000 -- up to 2 full hours (120 minutes)!
    local totalLoops = 0

    local function cleanupCodec()
        pcall(function() if fc then fc.close() end end)
        pcall(function() if fos then fos.close() end end)
        pcall(function() if codec then codec.stop(); codec.release() end end)
        pcall(function() if extractor then extractor.release() end end)
        fc = nil; fos = nil; codec = nil; extractor = nil
    end

    local okInit = pcall(function()
        local BufferInfoClass = luajava.bindClass("android.media.MediaCodec$BufferInfo")
        extractor = MediaExtractor()
        if inputUri ~= nil and not isTemp then
            local okU = pcall(function() extractor.setDataSource(context, inputUri, nil) end)
            if not okU then extractor.setDataSource(stagedPath) end
        else
            extractor.setDataSource(stagedPath)
        end
        local numTracks = extractor.getTrackCount()
        local audioTrack = -1
        local format = nil
        local mime = ""
        for i = 0, numTracks - 1 do
            local fmt = extractor.getTrackFormat(i)
            local m = fmt.getString("mime")
            if m and m:find("^audio/") then
                audioTrack = i; format = fmt; mime = m; break
            end
        end
        if audioTrack == -1 or not format then error("No audio track") end
        extractor.selectTrack(audioTrack)
        pcall(function() srcRate = format.getInteger("sample-rate") end)
        pcall(function() srcCh = format.getInteger("channel-count") end)

        codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, nil, nil, 0)
        codec.start()

        fos = FileOutputStream(File(tmpRaw))
        fc = fos.getChannel()
        info = BufferInfoClass()
    end)

    if not okInit or not codec or not fc then
        cleanupCodec()
        pcall(function() File(tmpRaw).delete() end)
        if isTemp then pcall(function() File(stagedPath).delete() end) end
        onDone(nil, 0, "Unsupported audio format")
        return
    end

    local function decodeNextCodecBatch()
        local okStep = pcall(function()
            local batch = 0
            while not outputEOS and batch < 30 and totalLoops < 2000000 do
                batch = batch + 1
                totalLoops = totalLoops + 1
                if not inputEOS then
                    local inIdx = codec.dequeueInputBuffer(0)
                    if inIdx >= 0 then
                        local inBuf = codec.getInputBuffer(inIdx)
                        local sampleSize = extractor.readSampleData(inBuf, 0)
                        if sampleSize < 0 then
                            codec.queueInputBuffer(inIdx, 0, 0, 0, 4)
                            inputEOS = true
                        else
                            local pts = extractor.getSampleTime()
                            local flags = (pts >= maxPtsUs) and 4 or 0
                            codec.queueInputBuffer(inIdx, 0, sampleSize, pts, flags)
                            extractor.advance()
                            if pts >= maxPtsUs then inputEOS = true end
                        end
                    end
                end
                local outIdx = codec.dequeueOutputBuffer(info, 0)
                if outIdx >= 0 then
                    local outBuf = codec.getOutputBuffer(outIdx)
                    if info.size > 0 and outBuf ~= nil then
                        outBuf.position(info.offset)
                        outBuf.limit(info.offset + info.size)
                        fc.write(outBuf)
                    end
                    codec.releaseOutputBuffer(outIdx, false)
                    if info.flags >= 4 or info.presentationTimeUs >= maxPtsUs then
                        outputEOS = true
                    end
                elseif outIdx == -2 then
                    local newFmt = codec.getOutputFormat()
                    pcall(function() srcRate = newFmt.getInteger("sample-rate") end)
                    pcall(function() srcCh = newFmt.getInteger("channel-count") end)
                end
            end
        end)

        if not okStep then
            cleanupCodec()
            pcall(function() File(tmpRaw).delete() end)
            if isTemp then pcall(function() File(stagedPath).delete() end) end
            onDone(nil, 0, "Audio decode error")
            return
        end

        if not outputEOS and totalLoops < 2000000 then
            delay(10, decodeNextCodecBatch)
        else
            cleanupCodec()
            local rawLen = tonumber(File(tmpRaw).length()) or 0
            delay(12, function() resampleRawFileTo24kDisk(tmpRaw, 0, rawLen, srcRate, srcCh, true) end)
        end
    end

    delay(12, decodeNextCodecBatch)
end

-- Downsample 24kHz mono PCM slice to compact 8000Hz mono WAV Base64 for fast Gemini audio understanding
local function encodePcm24kSliceToWav8kBase64(pcmSlice)
    local sByte = string.byte
    local sChar = string.char
    local totalFrames = math.floor(#pcmSlice / 2)
    local outParts = {}
    local oIdx = 0
    local blk = {}
    local bCnt = 0
    for f = 0, totalFrames - 1, 3 do
        local pos = f * 2 + 1
        local lo, hi = sByte(pcmSlice, pos, pos + 1)
        if lo and hi then
            bCnt = bCnt + 1
            blk[bCnt] = sChar(lo, hi)
            if bCnt >= 2048 then
                oIdx = oIdx + 1
                outParts[oIdx] = table.concat(blk)
                blk = {}; bCnt = 0
            end
        end
    end
    if bCnt > 0 then oIdx = oIdx + 1; outParts[oIdx] = table.concat(blk) end
    local pcm8k = table.concat(outParts)

    local tmpWav = context.getCacheDir().getPath() .. "/gem_chunk_" .. os.time() .. ".wav"
    local fos = FileOutputStream(File(tmpWav))
    writeWavHeader(fos, #pcm8k, 8000, 1)
    fos.close()
    local wf = io.open(tmpWav, "ab")
    if wf then wf:write(pcm8k); wf:close() end

    local b64Str = nil
    pcall(function()
        local fileObj = File(tmpWav)
        local fis = FileInputStream(fileObj)
        local len = tonumber(fileObj.length())
        local javaBytes = byte[len]
        local off = 0
        while off < len do
            local r = fis.read(javaBytes, off, len - off)
            if r <= 0 then break end
            off = off + r
        end
        fis.close()
        b64Str = Base64.encodeToString(javaBytes, Base64.NO_WRAP)
    end)
    pcall(function() File(tmpWav).delete() end)
    return b64Str
end

local function analyzeAudioChunkForSfxEvents(wavB64, chunkDurSec, apikey, callback, attempt)
    attempt = attempt or 1
    local activeKey = cleanApiKey(getCurrentApiKey())
    local validKeysList = "rain, rain_light, rain_roof, rain_drip, rain_indoor, thunder, wind, wind_breeze, leaves_rustle, tea_sip, cup_clink, stream_water, sea_waves, water_splash, fire, birds, forest_night, village_night, night_insects, dog_bark, footsteps, footsteps_wood, footsteps_gravel, footsteps_stairs, footsteps_mud, footsteps_forest, footsteps_run, footsteps_group, footsteps_heels, footsteps_soft, doorbell, knock, door_open, door_close, iron_door_open, iron_door_close, chains, car_start, car_drive, car_brakes, car_stop, car_door, car_horn, car_crash, phone_ring, phone_dial, heartbeat, crying_female, crying_male, scream_female, scream_male, scream_horror, gunshot, pistol_cock, glass_break, slap, punch, explosion, ambulance, police_siren"

    -- CRITICAL: Force Urdu Perso-Arabic script (NEVER Hindi Devanagari!) + also return optional sfx key backup!
    local prompt = [[Transcribe EVERY spoken sentence or clause in this ]] .. string.format("%.1f", chunkDurSec) .. [[-second audio clip with accurate start_sec and end_sec timestamps (between 0.0 and ]] .. string.format("%.1f", chunkDurSec) .. [[).
CRITICAL SCRIPT & SFX RULES:
1. IF the speaker is speaking Urdu or Hindi-Urdu, you MUST write "text" STRICTLY in Urdu Perso-Arabic script (اردو رسم الخط, e.g. "کال بیل کی آواز سنتے ہی", "اس نے دروازہ کھول دیا", "نمبر ڈائل کرنے شروع کر دیے"). NEVER use Hindi Devanagari script (हिन्दी) or Roman Urdu!
2. For each sentence, also include an optional "sfx" array of 0-2 exact keys from this allowed list ONLY when a real physical sound happens right then in that sentence (never for past-tense mentions, figurative phrases, threats, or negations): ]] .. validKeysList .. [[
3. Output ONLY a valid JSON array of objects:
   [{"start_sec":0.0,"end_sec":4.8,"text":"کال بیل کی آواز سنتے ہی عمران چونک پڑا","sfx":["doorbell"]}]
4. Do NOT skip any sentence. If silent, return [].]]

    local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. activeKey
    local body = {
        contents = {
            {
                parts = {
                    { text = prompt },
                    { inlineData = { mimeType = "audio/wav", data = wavB64 } }
                }
            }
        },
        generationConfig = {
            temperature = 0.1,
            maxOutputTokens = 2048,
            responseMimeType = "application/json"
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json; charset=UTF-8")

    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({ run = function()
        if not completed then
            completed = true
            if currentHttpRequest then pcall(function() currentHttpRequest.cancel() end) end
            if attempt < 3 then
                delay(2000, function() analyzeAudioChunkForSfxEvents(wavB64, chunkDurSec, getCurrentApiKey(), callback, attempt + 1) end)
            else
                callback(false, "Timeout (60s)", 408)
            end
        end
    end })
    timeoutHandler.postDelayed(timeoutRunnable, 60000)

    currentHttpRequest = Http.post(url, cjson.encode(body), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        currentHttpRequest = nil

        if code == 200 then
            consecutiveQuotaPauses = 0
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local cand = data.candidates[1]
                if cand and cand.content and cand.content.parts and #cand.content.parts > 0 then
                    local raw = tostring(cand.content.parts[1].text or "")
                    local cleaned = raw:gsub("```json\n?", ""):gsub("\n```", ""):gsub("```", "")
                    local s, e = cleaned:find("%[.*%]")
                    if s then cleaned = cleaned:sub(s, e) end
                    local okj, segments = pcall(cjson.decode, cleaned)
                    if okj and type(segments) == "table" then
                        local derivedEvents = {}
                        for _, seg in ipairs(segments) do
                            if type(seg) == "table" and seg.text and #tostring(seg.text) > 2 then
                                local segText = tostring(seg.text)
                                local segStart = math.max(0, tonumber(seg.start_sec) or 0)
                                local segEnd = tonumber(seg.end_sec) or math.min(chunkDurSec, segStart + 3.0)
                                if segEnd <= segStart + 0.3 then segEnd = math.min(chunkDurSec, segStart + 2.5) end
                                local segSpan = math.max(0.5, segEnd - segStart)

                                -- Primary: 100% deterministic Urdu/English keyword detector
                                local matches = detectAllLocalSfxForSentence(segText)
                                local seenInSeg = {}
                                for _, m in ipairs(matches) do
                                    local k = (type(m) == "table") and m.key or tostring(m or "")
                                    if k and k ~= "" and not seenInSeg[k] then
                                        seenInSeg[k] = true
                                        local isAmb = AMBIENT_SFX_SET[k] and true or false
                                        local kwFrac = findSfxTriggerFraction(segText, k)
                                        local evStart = segStart + (kwFrac * segSpan * 0.92)
                                        local evEnd = isAmb and math.min(chunkDurSec + 1.0, math.max(segEnd + 0.5, evStart + 3.6)) or (evStart + 2.1)
                                        table.insert(derivedEvents, {
                                            quote = segText,
                                            key = k,
                                            start_sec = evStart,
                                            end_sec = evEnd
                                        })
                                    end
                                end

                                -- Secondary backup: if local detector found nothing, accept valid Gemini seg.sfx tag (still guarded by threat filter!)
                                if #matches == 0 and type(seg.sfx) == "table" and not isThreatOrNegatedAction(segText) then
                                    for _, rawKey in ipairs(seg.sfx) do
                                        local k = tostring(rawKey or ""):lower()
                                        if k ~= "" and not seenInSeg[k] and not BLOCKED_VOCAL_SFX[k] then
                                            seenInSeg[k] = true
                                            local isAmb = AMBIENT_SFX_SET[k] and true or false
                                            local evStart = segStart + (segSpan * 0.35)
                                            local evEnd = isAmb and math.min(chunkDurSec + 1.0, math.max(segEnd + 0.5, evStart + 3.6)) or (evStart + 2.1)
                                            table.insert(derivedEvents, {
                                                quote = segText,
                                                key = k,
                                                start_sec = evStart,
                                                end_sec = evEnd
                                            })
                                        end
                                    end
                                end
                            end
                        end
                        callback(true, derivedEvents, 200)
                        return
                    end
                end
            end
            callback(true, {}, 200)
        else
            local errStr = extractApiError(code, content)
            markCurrentKeyDeadIfInvalid(code, errStr)
            if (code == 400 or code == 401 or code == 403 or code == 429 or code == 503) and switchToNextValidApiKey() then
                delay(900, function() analyzeAudioChunkForSfxEvents(wavB64, chunkDurSec, getCurrentApiKey(), callback, attempt) end)
            elseif attempt < 3 and code ~= 429 then
                delay(2000, function() analyzeAudioChunkForSfxEvents(wavB64, chunkDurSec, getCurrentApiKey(), callback, attempt + 1) end)
            else
                callback(false, errStr, code)
            end
        end
    end)
end

function generateAudioToSfx(audioPath, audioUri, apikey, generateBtn, playBtn, resultLayout)
    if (not audioPath or audioPath == "") and audioUri == nil then
        showToast("Please select an audio file first")
        isGenerating = false
        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("ADD SOUND EFFECTS") end
        return
    end

    resetApiFailoverState()
    startProgressBar(12)

    local pcm24kPath = nil
    local totalFrames = 0
    local chunkSec = 20.0
    local chunkFrames = math.floor(chunkSec * 24000)
    local chunkBytes = chunkFrames * 2
    local numChunks = 1
    local allEvents = {}
    local curIdx = 1

    local function finalizeMix()
        setProgressRange(80, 96)
        local loadedTracks = {}
        local validKeySet = {}
        for _, item in ipairs(REQUIRED_SFX_LIST) do validKeySet[item.key] = true end

        local activeEvents = {}
        for _, ev in ipairs(allEvents) do
            local k = tostring(ev.key or ""):lower()
            if validKeySet[k] and not BLOCKED_VOCAL_SFX[k] then
                if not loadedTracks[k] then
                    local wavPath = sfxCacheDir .. "/" .. k .. ".wav"
                    local f = io.open(wavPath, "rb")
                    if f then
                        local raw = f:read("*a")
                        f:close()
                        local info = parseWavMetadata(raw, k, AMBIENT_SFX_SET[k] and true or false)
                        if info and info.totalFrames > 100 then
                            loadedTracks[k] = info
                        end
                    end
                end
                if loadedTracks[k] then
                    local isAmb = AMBIENT_SFX_SET[k] and true or false
                    -- Small +0.28s alignment nudge on short action SFX so sounds land cleanly ON the action verb, not early!
                    local stSec = math.max(0, (tonumber(ev.start_sec) or 0) + (isAmb and 0.05 or 0.10))
                    local enSec = tonumber(ev.end_sec) or (stSec + (isAmb and 5.5 or 2.2))
                    if enSec <= stSec + 0.45 then enSec = stSec + (isAmb and 4.5 or 2.0) end
                    local stFrame = math.floor(stSec * 24000)
                    local enFrame = math.min(totalFrames, math.floor(enSec * 24000))
                    if stFrame < totalFrames and enFrame > stFrame then
                        table.insert(activeEvents, {
                            key = k,
                            track = loadedTracks[k],
                            isAmb = isAmb,
                            startFrame = stFrame,
                            endFrame = enFrame,
                            durFrames = enFrame - stFrame
                        })
                    end
                end
            end
        end

        -- Cooperative disk-streamed sliced mixing (1s per tick -> unlimited length, <3MB RAM, ZERO hang!)
        local sByte = string.byte
        local sChar = string.char
        local floor = math.floor
        local min = math.min

        local tempPath = context.getCacheDir().getPath() .. "/audio_sfx_" .. os.time() .. ".wav"
        local fos = FileOutputStream(File(tempPath))
        writeWavHeader(fos, totalFrames * 2, 24000, 1)
        fos.close()

        local inPcmF = io.open(pcm24kPath, "rb")
        local outWavF = io.open(tempPath, "ab")
        if not inPcmF or not outWavF then
            if inPcmF then inPcmF:close() end
            if outWavF then outWavF:close() end
            pcall(function() File(pcm24kPath).delete() end)
            stopProgressBar()
            showToast("Disk error while mixing audio")
            isGenerating = false
            if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("ADD SOUND EFFECTS") end
            return
        end

        local curFrame = 0
        local SLICE_FRAMES = 24000

        local function mixNextSlice()
            local endFrame = min(totalFrames, curFrame + SLICE_FRAMES)
            local sliceFramesCount = endFrame - curFrame
            local voiceSlice = inPcmF:read(sliceFramesCount * 2) or ""

            local sliceEvents = {}
            for _, ev in ipairs(activeEvents) do
                if ev.endFrame > curFrame and ev.startFrame < endFrame then
                    table.insert(sliceEvents, ev)
                end
            end

            if #sliceEvents == 0 then
                -- Fast zero-overhead passthrough when no SFX plays in this 1-second slice!
                outWavF:write(voiceSlice)
            else
                local outParts = {}
                local pIdx = 0
                local blk = {}
                local bCnt = 0

                for localF = 0, sliceFramesCount - 1 do
                    local outFrame = curFrame + localF
                    local vPos = localF * 2 + 1
                    local vlo, vhi = sByte(voiceSlice, vPos, vPos + 1)
                    local vSample = 0
                    if vlo and vhi then
                        vSample = vhi * 256 + vlo
                        if vSample >= 32768 then vSample = vSample - 65536 end
                    end

                    local ambSum = 0
                    local actSum = 0
                    local hasAct = false

                    for _, ev in ipairs(sliceEvents) do
                        if outFrame >= ev.startFrame and outFrame < ev.endFrame then
                            local rel = outFrame - ev.startFrame
                            local tr = ev.track
                            local srcFrame = floor(rel * tr.rateRatio)
                            if ev.isAmb then
                                srcFrame = srcFrame % tr.totalFrames
                            end
                            if srcFrame < tr.totalFrames then
                                local bPos = tr.dataStart + srcFrame * tr.frameSize
                                local slo, shi = sByte(tr.raw, bPos, bPos + 1)
                                if slo and shi then
                                    local sVal = shi * 256 + slo
                                    if sVal >= 32768 then sVal = sVal - 65536 end
                                    local fadeIn = min(ev.isAmb and 6000 or 960, floor(ev.durFrames * 0.15))
                                    local fadeOut = min(ev.isAmb and 6000 or 4800, floor(ev.durFrames * 0.25))
                                    local env = 1.0
                                    if fadeIn > 10 and rel < fadeIn then env = rel / fadeIn
                                    elseif fadeOut > 10 and (ev.durFrames - rel) < fadeOut then env = (ev.durFrames - rel) / fadeOut end

                                    if ev.isAmb then
                                        local level = 0.30
                                        if ev.key == "rain" or ev.key == "wind" or ev.key == "fire" then level = 0.26
                                        elseif ev.key == "rain_light" or ev.key == "rain_indoor" or ev.key == "wind_breeze" or ev.key == "leaves_rustle" then level = 0.22
                                        elseif ev.key == "rain_drip" then level = 0.28
                                        elseif ev.key == "birds" then level = 0.20
                                        elseif FOOTSTEP_SFX_SET[ev.key] then level = 0.24 end
                                        ambSum = ambSum + (sVal * tr.normGain * level * env)
                                    else
                                        hasAct = true
                                        local actLevel = 0.52
                                        if ev.key == "doorbell" then actLevel = 0.38
                                        elseif ev.key == "door_open" or ev.key == "door_close" or ev.key == "iron_door_open" or ev.key == "iron_door_close" then actLevel = 0.40
                                        elseif ev.key == "tea_sip" or ev.key == "cup_clink" or ev.key == "phone_dial" then actLevel = 0.34 end
                                        actSum = actSum + (sVal * tr.normGain * actLevel * env)
                                    end
                                end
                            end
                        end
                    end

                    local voiceGain = hasAct and 0.93 or 0.99
                    local ambDuck = hasAct and 0.45 or 1.0
                    local mixed = floor(vSample * voiceGain + ambSum * ambDuck + actSum)
                    if mixed > 32767 then mixed = 32767
                    elseif mixed < -32768 then mixed = -32768 end
                    if mixed < 0 then mixed = mixed + 65536 end

                    bCnt = bCnt + 1
                    blk[bCnt] = sChar(mixed % 256, floor(mixed / 256) % 256)
                    if bCnt >= 4096 then
                        pIdx = pIdx + 1
                        outParts[pIdx] = table.concat(blk)
                        blk = {}; bCnt = 0
                    end
                end
                if bCnt > 0 then pIdx = pIdx + 1; outParts[pIdx] = table.concat(blk) end
                outWavF:write(table.concat(outParts))
            end

            curFrame = endFrame
            local mixPct = 80 + floor((curFrame / math.max(1, totalFrames)) * 17)
            setProgressRange(mixPct, math.min(98, mixPct + 2))

            if curFrame < totalFrames then
                delay(10, mixNextSlice)
            else
                inPcmF:close()
                outWavF:close()
                pcall(function() File(pcm24kPath).delete() end)
                generatedAudioPath = tempPath
                finishProgressAndRun(function()
                    if appHidden then
                        appHidden = false; hiddenGenerating = false; showMainWithAudio()
                    else
                        if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                        initMediaPlayer()
                        pcall(function()
                            mediaPlayer.setDataSource(generatedAudioPath)
                            mediaPlayer.prepare()
                            applyPlaybackSpeed()
                        end)
                        if playBtn then playBtn.setEnabled(true); playBtn.setText("PLAY") end
                        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE SFX") end
                        showToast("Sound effects added (" .. tostring(#activeEvents) .. " effects)! 100%")
                    end
                    isGenerating = false
                end)
            end
        end

        delay(12, mixNextSlice)
    end

    local function processNextAudioChunk()
        if curIdx > numChunks then
            finalizeMix()
            return
        end

        local segStartPct = 18 + math.floor(((curIdx - 1) / numChunks) * 60)
        local segEndPct = 18 + math.floor((curIdx / numChunks) * 60)
        setProgressRange(segStartPct, segEndPct)

        local offsetBytes = (curIdx - 1) * chunkBytes
        local rf = io.open(pcm24kPath, "rb")
        local slice = nil
        if rf then
            rf:seek("set", offsetBytes)
            slice = rf:read(chunkBytes)
            rf:close()
        end
        if not slice or #slice < 400 then
            curIdx = curIdx + 1
            delay(100, processNextAudioChunk)
            return
        end

        local offsetSec = (curIdx - 1) * chunkSec
        local sliceDurSec = (#slice / 2) / 24000.0
        local wavB64 = encodePcm24kSliceToWav8kBase64(slice)

        if not wavB64 then
            curIdx = curIdx + 1
            delay(150, processNextAudioChunk)
            return
        end

        analyzeAudioChunkForSfxEvents(wavB64, sliceDurSec, getCurrentApiKey(), function(ok, eventsOrErr, httpCode)
            if ok and type(eventsOrErr) == "table" then
                for _, ev in ipairs(eventsOrErr) do
                    if type(ev) == "table" and ev.key then
                        local localStart = tonumber(ev.start_sec)
                        local qStr = tostring(ev.quote or "")
                        if localStart and localStart >= 0 and localStart <= sliceDurSec then
                            -- Guard: ignore boundary 0.0s hallucinations on chunk 2+ if Gemini gave no spoken quote
                            if not (curIdx > 1 and localStart < 0.25 and #qStr < 3) then
                                local localEnd = tonumber(ev.end_sec)
                                if localEnd then
                                    localEnd = math.min(sliceDurSec + 1.0, math.max(localStart + 1.0, localEnd))
                                end
                                table.insert(allEvents, {
                                    key = ev.key,
                                    start_sec = offsetSec + localStart,
                                    end_sec = localEnd and (offsetSec + localEnd) or nil
                                })
                            end
                        end
                    end
                end
                curIdx = curIdx + 1
                delay(300, processNextAudioChunk)
            elseif httpCode == 429 or httpCode == 401 or httpCode == 403 then
                showApiQuotaPausedDialog(curIdx - 1, numChunks, tostring(eventsOrErr), function()
                    processNextAudioChunk()
                end, function()
                    finalizeMix()
                end)
            else
                curIdx = curIdx + 1
                delay(300, processNextAudioChunk)
            end
        end)
    end

    -- Start cooperative disk-streamed decode (handles 25-min+ to 2-hour audios with ZERO OOM and ZERO hang!)
    delay(30, function()
        decodeFullUserAudioTo24kDiskAsync(audioPath, audioUri, function(decodedPath, decodedFrames, decErr)
            if not decodedPath or decodedFrames <= 0 then
                stopProgressBar()
                if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("ADD SOUND EFFECTS") end
                showToast("Error: " .. tostring(decErr or "Cannot read audio"))
                isGenerating = false
                return
            end
            pcm24kPath = decodedPath
            totalFrames = decodedFrames
            numChunks = math.max(1, math.ceil(totalFrames / chunkFrames))
            setProgressRange(15, 22)
            delay(25, processNextAudioChunk)
        end)
    end)
end

function showApiSettings(isFirstRun)
    if mainDialog ~= nil then
        pcall(function() mainDialog.dismiss() end)
        mainDialog = nil
    end

    loadApiKeys()
    local views = {}
    local layout = {
        LinearLayout, orientation = "vertical", padding = "22dp", layout_width = "fill", layout_height = "wrap", id = "apiDialogCard",
        {
            LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "apiHeaderBox", padding = "14dp", layout_marginBottom = "16dp",
            { TextView, id = "welcomeText", text = isFirstRun and "Welcome to Gemini AudioCraft!\n\nEnter up to 3 Gemini API keys for automatic switching when quota is reached." or "API CONFIGURATION", textSize = isFirstRun and 15 or 17, textColor = "#00E5FF", gravity = "center", typeface = Typeface.DEFAULT_BOLD }
        },

        {
            LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "apiBox1", padding = "12dp", layout_marginBottom = "12dp",
            { TextView, text = "API 1 (Required)", textSize = 13, textColor = "#FF4D6D", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
            { EditText, id = "apiInput1", hint = "Enter API key 1", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
        },

        {
            LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "apiBox2", padding = "12dp", layout_marginBottom = "12dp",
            { TextView, text = "API 2 (Optional)", textSize = 13, textColor = "#2ECC71", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
            { EditText, id = "apiInput2", hint = "Enter API key 2", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
        },

        {
            LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "apiBox3", padding = "12dp", layout_marginBottom = "14dp",
            { TextView, text = "API 3 (Optional)", textSize = 13, textColor = "#3498DB", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
            { EditText, id = "apiInput3", hint = "Enter API key 3", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
        },

        {
            LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", layout_marginTop = "6dp",
            { Button, id = "testBtn", text = "TEST ALL", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "13dp", layout_marginRight = "6dp", typeface = Typeface.DEFAULT_BOLD },
            { Button, id = "saveBtn", text = "SAVE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "13dp", layout_marginRight = "6dp", typeface = Typeface.DEFAULT_BOLD },
            { Button, id = "closeBtn", text = "CLOSE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "13dp", typeface = Typeface.DEFAULT_BOLD }
        }
    }
    local dlg = LuaDialog(context)
    dlg.setView(loadlayout(layout, views))
    pcall(function()
        views.apiDialogCard.setBackground(createGradientDrawable("#071324", "#102542", 24, "#00E5FF", 3))
        views.apiHeaderBox.setBackground(createCardDrawable("#0B1D36", 16, "#F39C12", 2))
        views.apiBox1.setBackground(createCardDrawable("#0D213F", 16, "#FF4D6D", 2))
        views.apiBox2.setBackground(createCardDrawable("#0D213F", 16, "#2ECC71", 2))
        views.apiBox3.setBackground(createCardDrawable("#0D213F", 16, "#3498DB", 2))
        views.apiInput1.setBackground(createCardDrawable("#081528", 12, "#FF4D6D", 1))
        views.apiInput2.setBackground(createCardDrawable("#081528", 12, "#2ECC71", 1))
        views.apiInput3.setBackground(createCardDrawable("#081528", 12, "#3498DB", 1))
        views.testBtn.setBackground(createGradientDrawable("#F39C12", "#D35400", 18, "#FDEBD0", 1))
        views.saveBtn.setBackground(createGradientDrawable("#27AE60", "#1E8449", 18, "#A9DFBF", 1))
        views.closeBtn.setBackground(createGradientDrawable("#576574", "#222F3E", 18, "#8395A7", 1))
    end)
    views.apiInput1.setText(rawKey1 or "")
    views.apiInput2.setText(rawKey2 or "")
    views.apiInput3.setText(rawKey3 or "")

    views.testBtn.onClick = function()
        vibrate(30)
        local k1 = cleanApiKey(views.apiInput1.getText().toString())
        local k2 = cleanApiKey(views.apiInput2.getText().toString())
        local k3 = cleanApiKey(views.apiInput3.getText().toString())

        views.apiInput1.setText(k1)
        views.apiInput2.setText(k2)
        views.apiInput3.setText(k3)

        local keys = {}
        if k1 ~= "" then table.insert(keys, {num = 1, key = k1}) end
        if k2 ~= "" then table.insert(keys, {num = 2, key = k2}) end
        if k3 ~= "" then table.insert(keys, {num = 3, key = k3}) end

        if #keys == 0 then showToast("Please enter at least one API key") return end

        views.testBtn.setText("Testing...")
        views.testBtn.setEnabled(false)

        local results = {}
        local completed = 0
        local total = #keys

        for _, item in ipairs(keys) do
            local keyIndex = item.num
            local keyVal = item.key
            local testUrl = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1&key=" .. keyVal
            Http.get(testUrl, function(code, content)
                runOnUi(function()
                    if code == 200 then
                        results[keyIndex] = "Valid"
                    elseif code == 429 then
                        results[keyIndex] = "Valid (Quota Full)"
                    else
                        results[keyIndex] = "Invalid (" .. tostring(code) .. ")"
                    end
                    completed = completed + 1
                    if completed >= total then
                        views.testBtn.setText("TEST ALL")
                        views.testBtn.setEnabled(true)

                        local lines = {}
                        local validCount = 0
                        local invalidCount = 0
                        for _, it in ipairs(keys) do
                            local status = results[it.num] or "Invalid"
                            if status:find("^Valid") then validCount = validCount + 1 else invalidCount = invalidCount + 1 end
                            table.insert(lines, "API " .. it.num .. ": " .. status)
                        end

                        local header = ""
                        if validCount == total then
                            header = "All " .. total .. " API key(s) are Valid"
                        elseif validCount == 0 then
                            header = "All " .. total .. " API key(s) are Invalid"
                        else
                            header = validCount .. " Valid, " .. invalidCount .. " Invalid"
                        end

                        local fullMsg = header .. "\n\n" .. table.concat(lines, "\n")

                        local rViews = {}
                        local rLayout = {
                            LinearLayout, orientation = "vertical", padding = "24dp", layout_width = "fill", layout_height = "wrap", id = "resultCard",
                            { TextView, text = "API Test Result", textSize = 18, textColor = "#F1C40F", gravity = "center", paddingBottom = "12dp", typeface = Typeface.DEFAULT_BOLD },
                            { TextView, id = "resultText", text = fullMsg, textSize = 14, textColor = "#FFFFFF", paddingBottom = "20dp" },
                            { Button, id = "okBtn", text = "OK", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "14dp", typeface = Typeface.DEFAULT_BOLD }
                        }
                        local rdlg = LuaDialog(context)
                        rdlg.setView(loadlayout(rLayout, rViews))
                        pcall(function()
                            rViews.resultCard.setBackground(createGradientDrawable("#0B192C", "#1E3E62", 22, "#F1C40F", 3))
                            rViews.okBtn.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 20, "#A9DFBF", 1))
                        end)
                        rViews.okBtn.onClick = function()
                            rdlg.dismiss()
                        end
                        rdlg.show()
                    end
                end)
            end)
        end
    end

    views.saveBtn.onClick = function()
        vibrate(30)
        local k1 = cleanApiKey(views.apiInput1.getText().toString())
        local k2 = cleanApiKey(views.apiInput2.getText().toString())
        local k3 = cleanApiKey(views.apiInput3.getText().toString())
        saveApiKeysToPrefs(k1, k2, k3)
        loadApiKeys()
        if isFirstRun then
            prefs.edit().putBoolean("firstRun", false).apply()
        end
        dlg.dismiss()
        delay(350, function() showMain() end)
    end
    views.closeBtn.onClick = function()
        vibrate(30)
        dlg.dismiss()
        if isFirstRun and (apiKeys[1] or "") == "" then
            closeAndCleanup()
        else
            delay(350, function() showMain() end)
        end
    end
    dlg.show()
end

-- ===== ABOUT DIALOG (STRUCTURED OVERVIEW, 4 MODES, KEY FEATURES & HOW TO USE) =====
function showAboutDialog()
    local views = {}
    local layout = {
        LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutCard", padding = "18dp",
        {
            LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutHeaderBox", padding = "16dp", layout_marginBottom = "14dp",
            { TextView, id = "devName", text = "Gemini AudioCraft", textSize = 22, textColor = "#F1C40F", gravity = "center", paddingBottom = "4dp", typeface = Typeface.DEFAULT_BOLD },
            { TextView, text = "Developer: Abdul Rehman", textSize = 15, textColor = "#FFFFFF", gravity = "center", paddingBottom = "4dp", typeface = Typeface.DEFAULT_BOLD },
            { TextView, text = "5-Mode AI Voice, Music, Podcast & Sound Effects Studio", textSize = 12, textColor = "#D2B4DE", gravity = "center" }
        },
        { ScrollView, layout_width = "fill", layout_height = "0dp", layout_weight = "1",
            { LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "4dp",

                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutSec1", padding = "14dp", layout_marginBottom = "12dp",
                    { TextView, text = "Extension Overview", textSize = 15, textColor = "#FF4D6D", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { TextView, text = "Gemini AudioCraft is an AI audio studio extension for Jieshuo powered by Google Gemini. It converts short or long scripts in Urdu, English, and other languages into studio-grade WAV audio across four dedicated modes, with automatic API switching and pause/resume protection.", textSize = 13, textColor = "#EAECEE" }
                },

                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutSec2", padding = "14dp", layout_marginBottom = "12dp",
                    { TextView, text = "All 5 Studio Modes", textSize = 15, textColor = "#00E5FF", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { TextView, text = "1. Text to Audio: Single-voice narration using 24 studio voices with Auto Smart Emotion or 40+ manual emotions and speed control (1.0x to 2.0x).\n\n2. Text to Music: Generates complete song lyrics from a theme (or uses your own lyrics) and performs a male-female vocal duet in 4 musical styles.\n\n3. Text to Podcast: Native multi-speaker Host and Guest studio conversation. AI Conversation turns any topic into a natural two-person discussion with mutual addressing, gender-aware grammar, intro, and outro; Direct Duet alternates your exact lines.\n\n4. Audio with Sound Effects: Story and audio-drama mode that reads your text with consistent narrator voice and smart auto-emotions (laughing, cheerful, angry, sad, fearful, surprised, whispering) while automatically mixing 54 situation-aware studio sound effects (rain, light rain, roof rain, water dripping, thunder, cool breeze, rustling leaves, tea sip, 7 surface-specific footsteps, car start/drive/brakes/stop/horn/crash, doorbell, wooden and iron doors, knock, heartbeat, crying, gunshot, glass break, ambulance, police siren, and morning birds) aligned directly to the spoken words.\n\n5. Audio to Sound Effects: Pick any existing audio file from your phone using the built-in Audio Picker (with total audio count, live search, and instant Play/Pause preview). Gemini listens to your audio and mixes matching studio sound effects at the exact timestamps without altering your original voice.", textSize = 13, textColor = "#EAECEE" }
                },

                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutSec3", padding = "14dp", layout_marginBottom = "12dp",
                    { TextView, text = "Key Features", textSize = 15, textColor = "#2ECC71", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { TextView, text = "• Long-Text Support: Handles very long scripts smoothly without skipping words.\n• Sequential Multi-API Switching: Add up to 3 Gemini API keys (API 1 -> API 2 -> API 3) with TEST ALL verification.\n• Smart Quota Pause & Resume: If all API keys reach their limit, generated audio is kept safely while an accurate cooldown timer runs; you can wait for auto-resume, add a new API key inline, or save partial audio.\n• Built-in Player & Safe Download: Play, rewind/forward 10s, adjust speed, hide to run in the background, and save WAV files directly to your Downloads folder.", textSize = 13, textColor = "#EAECEE" }
                },

                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutSec4", padding = "14dp", layout_marginBottom = "12dp",
                    { TextView, text = "How to Use", textSize = 15, textColor = "#F39C12", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { TextView, text = "Step 1: Open API settings, enter 1 to 3 Gemini API keys, tap TEST ALL, and tap SAVE.\nStep 2: Select your desired mode from Select Studio Mode (Text to Audio, Text to Music, Text to Podcast, or Audio with Sound Effects).\nStep 3: Paste or type your text, choose voices, emotion style, speed, and an optional file name.\nStep 4: Tap GENERATE. In Mode 4, allow the one-time sound effects download when prompted (you can cancel anytime).\nStep 5: Once finished, tap PLAY to preview or DOWNLOAD to save the WAV file.", textSize = 13, textColor = "#EAECEE" }
                },

                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutSec5", padding = "14dp", layout_marginBottom = "6dp",
                    { TextView, text = "Support & Feedback", textSize = 15, textColor = "#A29BFE", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { TextView, text = "Tap SEND FEEDBACK below to report an issue or share suggestions directly with the developer on WhatsApp.", textSize = 13, textColor = "#EAECEE" }
                }
            }
        },
        {
            LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", paddingTop = "12dp",
            { Button, id = "feedbackBtn", text = "SEND FEEDBACK", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "14dp", layout_marginRight = "8dp", textSize = 14, typeface = Typeface.DEFAULT_BOLD },
            { Button, id = "closeAboutBtn", text = "CLOSE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "14dp", layout_marginLeft = "8dp", textSize = 14, typeface = Typeface.DEFAULT_BOLD }
        }
    }
    local dlg = LuaDialog(context)
    dlg.setTitle(nil)
    dlg.setView(loadlayout(layout, views))
    dlg.setCancelable(true)
    pcall(function()
        views.aboutCard.setBackground(createGradientDrawable("#120924", "#1F1138", 24, "#F1C40F", 3))
        views.aboutHeaderBox.setBackground(createGradientDrawable("#1E0F3B", "#2C1654", 18, "#FF4D6D", 2))
        views.aboutSec1.setBackground(createCardDrawable("#1A1032", 16, "#FF4D6D", 2))
        views.aboutSec2.setBackground(createCardDrawable("#12262A", 16, "#2ECC71", 2))
        views.aboutSec3.setBackground(createCardDrawable("#291A10", 16, "#F39C12", 2))
        views.aboutSec4.setBackground(createCardDrawable("#0F2038", 16, "#00E5FF", 2))
        views.aboutSec5.setBackground(createCardDrawable("#191536", 16, "#A29BFE", 2))
        views.feedbackBtn.setBackground(createGradientDrawable("#25D366", "#128C7E", 22, "#A9DFBF", 1))
        views.closeAboutBtn.setBackground(createGradientDrawable("#636E72", "#2D3436", 22, "#B2BEC3", 1))
        local param = dlg.getWindow().getAttributes()
        param.dimAmount = 0.65
        dlg.getWindow().setAttributes(param)
    end)

    views.feedbackBtn.onClick = function()
        vibrate(40)
        dlg.dismiss()
        if mainDialog then mainDialog.dismiss() end
        closeAndCleanup()
        local phone = "+923124255300"
        local message = "Hello Abdul Rehman! I'm using Gemini AudioCraft. Here is my feedback:"
        local url = "https://wa.me/" .. phone:gsub("+", "") .. "?text=" .. Uri.encode(message)
        local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        context.startActivity(intent)
    end

    views.closeAboutBtn.onClick = function()
        vibrate(30)
        dlg.dismiss()
    end
    dlg.show()
end

function showMainWithAudio()
    runOnUi(function()
        showMain()
        delay(600, function()
            if mainDialog and generatedAudioPath then
                if currentResultLayout then
                    currentResultLayout.setVisibility(View.VISIBLE)
                    initMediaPlayer()
                    pcall(function()
                        mediaPlayer.setDataSource(generatedAudioPath)
                        mediaPlayer.prepare()
                        applyPlaybackSpeed()
                    end)
                    if currentPlayBtn then
                        currentPlayBtn.setEnabled(true)
                        currentPlayBtn.setText("PLAY")
                    end
                    if currentGenerateBtn then
                        currentGenerateBtn.setEnabled(true)
                        if isMusicMode then
                            currentGenerateBtn.setText("REGENERATE MUSIC")
                        elseif isPodcastMode then
                            currentGenerateBtn.setText("REGENERATE PODCAST")
                        elseif isSfxMode then
                            currentGenerateBtn.setText("REGENERATE SFX AUDIO")
                        else
                            currentGenerateBtn.setText("REGENERATE AUDIO")
                        end
                    end
                    showToast("Audio ready! 100%")
                end
            end
        end)
    end)
end

-- ===== MAIN UI (WITH DYNAMIC PER-MODE & PER-EMOTION LUXURY VISUAL THEMES) =====
function showMain()
    if mainDialog ~= nil then
        pcall(function() mainDialog.dismiss() end)
        mainDialog = nil
    end

    loadSettings()
    initMediaPlayer()
    initTTS()
    appHidden = false
    hiddenGenerating = false

    local views = {}
    local scrollLayout = {
        ScrollView, layout_width = "fill", layout_height = "fill", id = "windowBackground",
        {
            LinearLayout, orientation = "vertical", padding = "18dp", layout_width = "fill", layout_height = "wrap",
            {
                LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "headerCard", padding = "14dp", layout_marginBottom = "14dp",
                { TextView, id = "mainTitleText", text = "Gemini AudioCraft", textSize = 23, textColor = "#FFFFFF", gravity = "center", typeface = Typeface.DEFAULT_BOLD },
                { TextView, id = "mainSubText", text = "Developed by Abdul Rehman", textSize = 13, textColor = "#E2E8F0", gravity = "center", paddingTop = "3dp", typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC) }
            },
            {
                LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "modeBarCard", padding = "12dp", layout_marginBottom = "14dp",
                { TextView, id = "modeLabelText", text = "Select Studio Mode", textSize = 12, textColor = "#F1C40F", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                { Spinner, id = "modeSpinner", layout_width = "fill", layout_height = "46dp" }
            },
            {
                LinearLayout, id = "commonTextLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = (not isMusicMode and not isAudioSfxMode) and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "cardText", padding = "14dp", layout_marginBottom = "14dp",
                    { TextView, id = "scriptBoxLabel", text = "Story / Script Input", textSize = 12, textColor = "#FFFFFF", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "textInput", hint = "Type your story or script here...", layout_width = "fill", layout_height = "130dp", backgroundColor = "#00000000", padding = "12dp", gravity = Gravity.TOP, textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            {
                LinearLayout, id = "audioSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = (not isMusicMode and not isPodcastMode and not isAudioSfxMode) and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "cardSettings", padding = "15dp", layout_marginBottom = "14dp",
                    {
                        LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "voiceCardBox", padding = "10dp", layout_marginBottom = "10dp",
                        { TextView, id = "voiceLabelText", text = "Select Voice", textSize = 12, textColor = "#00E5FF", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                        { Spinner, id = "voiceSpin", layout_width = "fill", layout_height = "45dp" }
                    },
                    {
                        LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "emotionCardBox", padding = "10dp", layout_marginBottom = "10dp",
                        { TextView, id = "emotionLabelText", text = "Emotion / Expression Style", textSize = 12, textColor = "#F1C40F", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                        { Spinner, id = "emotionSpin", layout_width = "fill", layout_height = "45dp" }
                    },
                    {
                        LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "speedCardBox", padding = "10dp", layout_marginBottom = "10dp",
                        { TextView, text = "Playback Speed", textSize = 12, textColor = "#2ECC71", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                        { Spinner, id = "speedSpin", layout_width = "fill", layout_height = "45dp" }
                    },
                    { TextView, text = "Save File Name", textSize = 12, textColor = "#EAECEE", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "fileNameInput", hint = "e.g. my_audio_file", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "10dp", textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            {
                LinearLayout, id = "musicSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = isMusicMode and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "15dp", layout_marginBottom = "14dp", id = "musicCard",
                    { TextView, text = "Music Style", textSize = 12, textColor = "#2ECC71", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "styleSpinner", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "14dp" },
                    { TextView, text = "Lyrics (Optional)", textSize = 12, textColor = "#00E5FF", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "lyricsInput", hint = "Write lyrics or leave empty", layout_width = "fill", layout_height = "100dp", backgroundColor = "#00000000", padding = "10dp", gravity = Gravity.TOP, textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF", layout_marginBottom = "14dp" },
                    { TextView, text = "Song Theme", textSize = 12, textColor = "#F1C40F", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "themeInput", hint = "e.g. 'A sad romantic song'", layout_width = "fill", layout_height = "80dp", backgroundColor = "#00000000", padding = "10dp", gravity = Gravity.TOP, textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            {
                LinearLayout, id = "podcastSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = isPodcastMode and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "15dp", layout_marginBottom = "14dp", id = "podcastCard",
                    { TextView, text = "Host Voice", textSize = 12, textColor = "#F39C12", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "hostVoiceSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "12dp" },
                    { TextView, text = "Guest Voice", textSize = 12, textColor = "#00E5FF", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "guestVoiceSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "12dp" },
                    { TextView, text = "Podcast Mode", textSize = 12, textColor = "#2ECC71", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { RadioGroup, id = "podcastModeGroup", layout_width = "fill", layout_height = "wrap", orientation = "horizontal", layout_marginBottom = "12dp",
                        { RadioButton, id = "aiModeRadio", text = "AI Conversation", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF" },
                        { RadioButton, id = "directModeRadio", text = "Direct Duet", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF" }
                    },
                    { TextView, text = "Playback Speed", textSize = 12, textColor = "#F1C40F", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "speedSpinPodcast", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "14dp" },
                    { TextView, text = "Save File Name", textSize = 12, textColor = "#EAECEE", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "fileNameInputPodcast", hint = "e.g. my_podcast", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "10dp", textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            {
                LinearLayout, id = "audioSfxSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = isAudioSfxMode and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "15dp", layout_marginBottom = "14dp", id = "audioSfxCard",
                    { TextView, text = "Select Mobile Audio", textSize = 12, textColor = "#D980FA", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "8dp" },
                    { Button, id = "selectAudioBtn", text = "SELECT AUDIO", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "14dp", textSize = 14, typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "10dp" },
                    {
                        LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "selectedAudioInfoBox", padding = "12dp", layout_marginBottom = "12dp",
                        { TextView, id = "selectedAudioText", text = (selectedInputAudioName ~= "" and ("Selected: " .. selectedInputAudioName) or "No audio selected yet"), textSize = 13, textColor = "#00E5FF" }
                    },
                    { TextView, text = "Playback Speed", textSize = 12, textColor = "#2ECC71", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "speedSpinAudioSfx", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "14dp" },
                    { TextView, text = "Save File Name", textSize = 12, textColor = "#EAECEE", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "fileNameInputAudioSfx", hint = "e.g. my_audio_with_sfx", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "10dp", textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            { Button, id = "generateBtn", text = (isMusicMode and "GENERATE MUSIC") or (isPodcastMode and "GENERATE PODCAST") or (isSfxMode and "GENERATE SFX AUDIO") or (isAudioSfxMode and "ADD SOUND EFFECTS") or "GENERATE AUDIO", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "16dp", textSize = 15, typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "12dp" },
            { TextView, id = "progressText", text = "1%", textSize = 16, textColor = "#2ECC71", gravity = "center", padding = "12dp", layout_width = "fill", layout_height = "wrap", visibility = isGenerating and View.VISIBLE or View.GONE, layout_marginBottom = "15dp", typeface = Typeface.DEFAULT_BOLD },
            {
                LinearLayout, id = "resultLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = View.GONE, layout_marginBottom = "15dp", padding = "15dp",
                { TextView, text = "AUDIO PLAYER", textSize = 12, textColor = "#2ECC71", gravity = "center", layout_marginBottom = "10dp", typeface = Typeface.DEFAULT_BOLD },
                {
                    LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", gravity = "center",
                    { Button, id = "rwBtn", text = "10s", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", layout_marginRight = "6dp", padding = "12dp" },
                    { Button, id = "playBtn", text = "PLAY", layout_width = "0dp", layout_weight = "1.4", textColor = "#FFFFFF", layout_marginRight = "6dp", enabled = false, typeface = Typeface.DEFAULT_BOLD, padding = "12dp" },
                    { Button, id = "ffBtn", text = "10s", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp" }
                },
                { Button, id = "downloadBtn", text = "DOWNLOAD", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", layout_marginTop = "12dp", padding = "12dp", typeface = Typeface.DEFAULT_BOLD }
            },
            {
                LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", paddingTop = "8dp",
                { Button, id = "apiBtn", text = "API", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD, layout_marginRight = "4dp" },
                { Button, id = "hideBtn", text = "HIDE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD, layout_marginRight = "4dp" },
                { Button, id = "aboutBtn", text = "ABOUT", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD, layout_marginRight = "4dp" },
                { Button, id = "exitBtn", text = "EXIT", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD }
            }
        }
    }

    local dlg = LuaDialog(context)
    dlg.setCancelable(false)
    dlg.setView(loadlayout(scrollLayout, views))
    mainDialog = dlg
    currentGenerateBtn = views.generateBtn
    currentPlayBtn = views.playBtn
    currentResultLayout = views.resultLayout
    currentProgressText = views.progressText

    dlg.setOnDismissListener({ onDismiss = function()
        if not hiddenGenerating then closeAndCleanup() end
    end })

    if isGenerating then
        views.generateBtn.setEnabled(false)
        views.generateBtn.setText("GENERATING, PLEASE WAIT...")
        if views.progressText then
            views.progressText.setVisibility(View.VISIBLE)
            views.progressText.setText(math.max(1, math.floor(progressPercent)) .. "%")
        end
    elseif generatedAudioPath ~= nil then
        views.generateBtn.setEnabled(true)
        views.generateBtn.setText("REGENERATE")
        if views.resultLayout then
            views.resultLayout.setVisibility(View.VISIBLE)
            initMediaPlayer()
            pcall(function()
                mediaPlayer.setDataSource(generatedAudioPath)
                mediaPlayer.prepare()
                applyPlaybackSpeed()
            end)
            if views.playBtn then
                views.playBtn.setEnabled(true)
                views.playBtn.setText("PLAY")
            end
        end
    else
        views.generateBtn.setEnabled(true)
    end

    -- Dynamic Emotion Box Theme Helper (changes border and glow according to selected emotion)
    local function applyEmotionVisualTheme(emName)
        pcall(function()
            if not views.emotionCardBox or not views.emotionSpin then return end
            local em = tostring(emName or selectedEmotion)
            local borderCol = "#F1C40F"
            local boxBg = "#1B1530"
            local spinBg = "#120E24"
            if em:find("Auto") then
                borderCol = "#F1C40F"; boxBg = "#241A12"; spinBg = "#17110B"
            elseif em == "Happy" or em == "Cheerful" or em == "Excited" or em == "Playful" or em == "Funny" or em == "Energetic" then
                borderCol = "#2ECC71"; boxBg = "#0E241B"; spinBg = "#091812"
            elseif em == "Sad" or em == "Gloomy" or em == "Desperate" then
                borderCol = "#3498DB"; boxBg = "#0E1D2F"; spinBg = "#08121E"
            elseif em == "Angry" or em == "Bold" or em == "Strong" or em == "Passionate" then
                borderCol = "#FF4D6D"; boxBg = "#2A0F1D"; spinBg = "#1A0912"
            elseif em == "Fearful" or em == "Mysterious" or em == "Whisper" or em == "Surprised" then
                borderCol = "#A29BFE"; boxBg = "#191332"; spinBg = "#100B22"
            elseif em == "Romantic" or em == "Loving" or em == "Gentle" then
                borderCol = "#FD79A8"; boxBg = "#281124"; spinBg = "#190A16"
            end
            views.emotionCardBox.setBackground(createCardDrawable(boxBg, 14, borderCol, 2))
            views.emotionSpin.setBackground(createCardDrawable(spinBg, 10, borderCol, 1))
        end)
    end

    -- Dynamic Mode Visual Theme Helper (gives each of the 4 modes its own distinct luxury card & border design)
    local function applyModeVisualTheme(modePos)
        pcall(function()
            if modePos == 0 then
                -- Mode 1: Text to Audio (Royal Crimson & Midnight Navy Studio)
                views.windowBackground.setBackground(createGradientDrawable("#0B0C1E", "#1A1230", 24, "#FF4D6D", 2))
                views.headerCard.setBackground(createGradientDrawable("#16112E", "#281332", 18, "#FF4D6D", 2))
                views.modeBarCard.setBackground(createCardDrawable("#14162D", 16, "#FF4D6D", 2))
                views.modeSpinner.setBackground(createCardDrawable("#0D0F22", 12, "#F1C40F", 1))
                views.cardText.setBackground(createCardDrawable("#12152B", 18, "#FF4D6D", 2))
                views.textInput.setBackground(createCardDrawable("#0B0D1D", 12, "#E94560", 1))
                views.cardSettings.setBackground(createCardDrawable("#12152B", 18, "#9B59B6", 2))
                views.voiceCardBox.setBackground(createCardDrawable("#171C36", 14, "#00E5FF", 2))
                views.voiceSpin.setBackground(createCardDrawable("#0E1226", 10, "#00E5FF", 1))
                views.speedCardBox.setBackground(createCardDrawable("#14222E", 14, "#2ECC71", 2))
                views.speedSpin.setBackground(createCardDrawable("#0C161F", 10, "#2ECC71", 1))
                views.fileNameInput.setBackground(createCardDrawable("#0D0F22", 12, "#FF4D6D", 1))
                views.generateBtn.setBackground(createGradientDrawable("#FF4D6D", "#C9184A", 28, "#FF8FA3", 2))
                applyEmotionVisualTheme(selectedEmotion)
            elseif modePos == 1 then
                -- Mode 2: Text to Music (Emerald & Neon Teal Concert Studio)
                views.windowBackground.setBackground(createGradientDrawable("#06171B", "#0E2A30", 24, "#2ECC71", 2))
                views.headerCard.setBackground(createGradientDrawable("#0B262C", "#113B42", 18, "#2ECC71", 2))
                views.modeBarCard.setBackground(createCardDrawable("#0A2227", 16, "#00E5FF", 2))
                views.modeSpinner.setBackground(createCardDrawable("#07171B", 12, "#2ECC71", 1))
                views.musicCard.setBackground(createCardDrawable("#0A2227", 18, "#2ECC71", 2))
                views.styleSpinner.setBackground(createCardDrawable("#07171B", 12, "#2ECC71", 1))
                views.lyricsInput.setBackground(createCardDrawable("#07171B", 12, "#00E5FF", 1))
                views.themeInput.setBackground(createCardDrawable("#07171B", 12, "#F1C40F", 1))
                views.generateBtn.setBackground(createGradientDrawable("#1ABC9C", "#117864", 28, "#A3E4D7", 2))
            elseif modePos == 2 then
                -- Mode 3: Text to Podcast (Royal Amber Gold & Sunset Broadcast Studio)
                views.windowBackground.setBackground(createGradientDrawable("#180F08", "#2B1A0E", 24, "#F39C12", 2))
                views.headerCard.setBackground(createGradientDrawable("#26160B", "#3B2210", 18, "#F39C12", 2))
                views.modeBarCard.setBackground(createCardDrawable("#22140A", 16, "#F39C12", 2))
                views.modeSpinner.setBackground(createCardDrawable("#160C06", 12, "#F1C40F", 1))
                views.cardText.setBackground(createCardDrawable("#22140A", 18, "#E67E22", 2))
                views.textInput.setBackground(createCardDrawable("#150C06", 12, "#F39C12", 1))
                views.podcastCard.setBackground(createCardDrawable("#22140A", 18, "#F39C12", 2))
                views.hostVoiceSpin.setBackground(createCardDrawable("#150C06", 12, "#F39C12", 1))
                views.guestVoiceSpin.setBackground(createCardDrawable("#150C06", 12, "#00E5FF", 1))
                views.speedSpinPodcast.setBackground(createCardDrawable("#150C06", 12, "#2ECC71", 1))
                views.fileNameInputPodcast.setBackground(createCardDrawable("#150C06", 12, "#F39C12", 1))
                views.generateBtn.setBackground(createGradientDrawable("#F39C12", "#D35400", 28, "#FDEBD0", 2))
            elseif modePos == 3 then
                -- Mode 4: Audio with Sound Effects (Electric Cyan & Neon Indigo Cinema SFX Studio)
                views.windowBackground.setBackground(createGradientDrawable("#071324", "#112240", 24, "#00E5FF", 2))
                views.headerCard.setBackground(createGradientDrawable("#0C1E38", "#163056", 18, "#00E5FF", 2))
                views.modeBarCard.setBackground(createCardDrawable("#0B1A30", 16, "#00E5FF", 2))
                views.modeSpinner.setBackground(createCardDrawable("#071120", 12, "#00E5FF", 1))
                views.cardText.setBackground(createCardDrawable("#0B1A30", 18, "#00E5FF", 2))
                views.textInput.setBackground(createCardDrawable("#071120", 12, "#00CEC9", 1))
                views.cardSettings.setBackground(createCardDrawable("#0B1A30", 18, "#A29BFE", 2))
                views.voiceCardBox.setBackground(createCardDrawable("#102340", 14, "#00E5FF", 2))
                views.voiceSpin.setBackground(createCardDrawable("#081426", 10, "#00E5FF", 1))
                views.speedCardBox.setBackground(createCardDrawable("#0E2433", 14, "#2ECC71", 2))
                views.speedSpin.setBackground(createCardDrawable("#081620", 10, "#2ECC71", 1))
                views.fileNameInput.setBackground(createCardDrawable("#071120", 12, "#00E5FF", 1))
                views.generateBtn.setBackground(createGradientDrawable("#00B4DB", "#0083B0", 28, "#80FFDB", 2))
                applyEmotionVisualTheme(selectedEmotion)
            else
                -- Mode 5: Audio to Sound Effects (Electric Violet & Neon Magenta Audio FX Studio)
                views.windowBackground.setBackground(createGradientDrawable("#120824", "#241042", 24, "#D980FA", 2))
                views.headerCard.setBackground(createGradientDrawable("#1E0D3B", "#31145E", 18, "#D980FA", 2))
                views.modeBarCard.setBackground(createCardDrawable("#1A0C33", 16, "#D980FA", 2))
                views.modeSpinner.setBackground(createCardDrawable("#110724", 12, "#00E5FF", 1))
                views.audioSfxCard.setBackground(createCardDrawable("#1A0C33", 18, "#D980FA", 2))
                views.selectAudioBtn.setBackground(createGradientDrawable("#8E44AD", "#6C3483", 20, "#D980FA", 2))
                views.selectedAudioInfoBox.setBackground(createCardDrawable("#120826", 14, "#00E5FF", 1))
                views.speedSpinAudioSfx.setBackground(createCardDrawable("#110724", 12, "#2ECC71", 1))
                views.fileNameInputAudioSfx.setBackground(createCardDrawable("#110724", 12, "#D980FA", 1))
                views.generateBtn.setBackground(createGradientDrawable("#9B59B6", "#6C3483", 28, "#E8A2FF", 2))
            end

            if views.progressText then views.progressText.setBackground(createCardDrawable("#0B2420", 16, "#2ECC71", 2)) end
            views.resultLayout.setBackground(createGradientDrawable("#0B1D36", "#132B4D", 20, "#2ECC71", 2))
            views.rwBtn.setBackground(createGradientDrawable("#2C3E50", "#34495E", 18, "#7F8C8D", 1))
            views.playBtn.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 18, "#A9DFBF", 1))
            views.ffBtn.setBackground(createGradientDrawable("#2C3E50", "#34495E", 18, "#7F8C8D", 1))
            views.downloadBtn.setBackground(createGradientDrawable("#E67E22", "#D35400", 18, "#FDEBD0", 1))
            views.apiBtn.setBackground(createGradientDrawable("#8E44AD", "#6C3483", 18, "#D2B4DE", 1))
            views.hideBtn.setBackground(createGradientDrawable("#2980B9", "#1F618D", 18, "#A9CCE3", 1))
            views.aboutBtn.setBackground(createGradientDrawable("#F39C12", "#B9770E", 18, "#F9E79F", 1))
            views.exitBtn.setBackground(createGradientDrawable("#C0392B", "#922B21", 18, "#F5B7B1", 1))
        end)
    end

    if savedText ~= "" then views.textInput.setText(savedText); userText = savedText end
    if savedFileName == "" and userFileName ~= "" then savedFileName = userFileName end
    if savedFileName ~= "" then
        if views.fileNameInput then views.fileNameInput.setText(savedFileName) end
        if views.fileNameInputPodcast then views.fileNameInputPodcast.setText(savedFileName) end
        userFileName = savedFileName
    end

    views.textInput.addTextChangedListener({ afterTextChanged = function(e) userText = e.toString(); savedText = userText end })
    if views.fileNameInput then
        views.fileNameInput.addTextChangedListener({ afterTextChanged = function(e) userFileName = e.toString(); savedFileName = userFileName; saveSettings() end })
    end
    if views.fileNameInputPodcast then
        views.fileNameInputPodcast.addTextChangedListener({ afterTextChanged = function(e) userFileName = e.toString(); savedFileName = userFileName; saveSettings() end })
    end

    local MODES = {"Text to Audio", "Text to Music", "Text to Podcast", "Audio with Sound Effects", "Audio to Sound Effects"}
    local modeAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, MODES)
    modeAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.modeSpinner.setAdapter(modeAdapter)
    local modeIndex = 0
    if isMusicMode then modeIndex = 1
    elseif isPodcastMode then modeIndex = 2
    elseif isSfxMode then modeIndex = 3
    elseif isAudioSfxMode then modeIndex = 4
    else modeIndex = 0 end
    views.modeSpinner.setSelection(modeIndex)
    applyModeVisualTheme(modeIndex)

    views.modeSpinner.onItemSelectedListener = {
        onItemSelected = function(p, v, pos, id)
            applyModeVisualTheme(pos)
            if pos == 0 then
                isMusicMode = false; isPodcastMode = false; isSfxMode = false; isAudioSfxMode = false
                views.commonTextLayout.setVisibility(View.VISIBLE)
                views.audioSettingsLayout.setVisibility(View.VISIBLE)
                views.musicSettingsLayout.setVisibility(View.GONE)
                views.podcastSettingsLayout.setVisibility(View.GONE)
                views.audioSfxSettingsLayout.setVisibility(View.GONE)
                if not isGenerating then views.generateBtn.setText("GENERATE AUDIO") end
                saveSettings()
            elseif pos == 1 then
                isMusicMode = true; isPodcastMode = false; isSfxMode = false; isAudioSfxMode = false
                views.commonTextLayout.setVisibility(View.GONE)
                views.audioSettingsLayout.setVisibility(View.GONE)
                views.musicSettingsLayout.setVisibility(View.VISIBLE)
                views.podcastSettingsLayout.setVisibility(View.GONE)
                views.audioSfxSettingsLayout.setVisibility(View.GONE)
                if not isGenerating then views.generateBtn.setText("GENERATE MUSIC") end
                saveSettings()
            elseif pos == 2 then
                isMusicMode = false; isPodcastMode = true; isSfxMode = false; isAudioSfxMode = false
                views.commonTextLayout.setVisibility(View.VISIBLE)
                views.audioSettingsLayout.setVisibility(View.GONE)
                views.musicSettingsLayout.setVisibility(View.GONE)
                views.podcastSettingsLayout.setVisibility(View.VISIBLE)
                views.audioSfxSettingsLayout.setVisibility(View.GONE)
                if not isGenerating then views.generateBtn.setText("GENERATE PODCAST") end
                if podcastGenerationMode == 1 then views.aiModeRadio.setChecked(true) else views.directModeRadio.setChecked(true) end
                saveSettings()
            elseif pos == 3 then
                isMusicMode = false; isPodcastMode = false; isSfxMode = true; isAudioSfxMode = false
                views.commonTextLayout.setVisibility(View.VISIBLE)
                views.audioSettingsLayout.setVisibility(View.VISIBLE)
                views.musicSettingsLayout.setVisibility(View.GONE)
                views.podcastSettingsLayout.setVisibility(View.GONE)
                views.audioSfxSettingsLayout.setVisibility(View.GONE)
                if not isGenerating then views.generateBtn.setText("GENERATE SFX AUDIO") end
                saveSettings()
                if not isSfxPackReady() then
                    promptAndDownloadSfxPack(
                        function() end,
                        function()
                            if views.modeSpinner then views.modeSpinner.setSelection(0) end
                        end
                    )
                end
            else
                isMusicMode = false; isPodcastMode = false; isSfxMode = false; isAudioSfxMode = true
                views.commonTextLayout.setVisibility(View.GONE)
                views.audioSettingsLayout.setVisibility(View.GONE)
                views.musicSettingsLayout.setVisibility(View.GONE)
                views.podcastSettingsLayout.setVisibility(View.GONE)
                views.audioSfxSettingsLayout.setVisibility(View.VISIBLE)
                if not isGenerating then views.generateBtn.setText("ADD SOUND EFFECTS") end
                saveSettings()
                if not isSfxPackReady() then
                    promptAndDownloadSfxPack(
                        function() end,
                        function()
                            if views.modeSpinner then views.modeSpinner.setSelection(0) end
                        end
                    )
                end
            end
        end
    }

    if views.voiceSpin then
        local voiceAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
        voiceAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.voiceSpin.setAdapter(voiceAdapter)
        for i, v in ipairs(VOICE_LIST) do if v == selectedVoice then views.voiceSpin.setSelection(i - 1) end end
        views.voiceSpin.onItemSelectedListener = { onItemSelected = function(p, v, pos) selectedVoice = VOICE_LIST[pos + 1]; saveSettings() end }
    end

    if views.emotionSpin then
        local emotionAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, EMOTIONS)
        emotionAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.emotionSpin.setAdapter(emotionAdapter)
        for i, e in ipairs(EMOTIONS) do if e == selectedEmotion then views.emotionSpin.setSelection(i - 1) end end
        views.emotionSpin.onItemSelectedListener = {
            onItemSelected = function(p, v, pos, id)
                selectedEmotion = EMOTIONS[pos + 1]
                applyEmotionVisualTheme(selectedEmotion)
                saveSettings()
            end
        }
    end

    if views.speedSpin then
        local speedAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, SPEED_LIST)
        speedAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.speedSpin.setAdapter(speedAdapter)
        for i, v in ipairs(SPEED_VALUES) do if v == currentSpeedValue then views.speedSpin.setSelection(i - 1) end end
        views.speedSpin.onItemSelectedListener = { onItemSelected = function(p, v, pos) currentSpeedValue = SPEED_VALUES[pos + 1]; applyPlaybackSpeed() end }
    end

    if views.styleSpinner then
        local styleAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, MUSIC_STYLES)
        styleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.styleSpinner.setAdapter(styleAdapter)
        for i, s in ipairs(MUSIC_STYLES) do if s == selectedMusicStyle then views.styleSpinner.setSelection(i - 1) end end
        views.styleSpinner.onItemSelectedListener = { onItemSelected = function(p, v, pos) selectedMusicStyle = MUSIC_STYLES[pos + 1]; saveSettings() end }
    end

    if views.hostVoiceSpin then
        local hostAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
        hostAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.hostVoiceSpin.setAdapter(hostAdapter)
        for i, v in ipairs(VOICE_LIST) do if v == selectedVoice then views.hostVoiceSpin.setSelection(i - 1) end end
        views.hostVoiceSpin.onItemSelectedListener = { onItemSelected = function(p, v, pos) selectedVoice = VOICE_LIST[pos + 1]; saveSettings() end }
    end

    if views.guestVoiceSpin then
        local guestAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
        guestAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.guestVoiceSpin.setAdapter(guestAdapter)
        for i, v in ipairs(VOICE_LIST) do if v == selectedVoice2 then views.guestVoiceSpin.setSelection(i - 1) end end
        views.guestVoiceSpin.onItemSelectedListener = { onItemSelected = function(p, v, pos) selectedVoice2 = VOICE_LIST[pos + 1]; saveSettings() end }
    end

    if views.speedSpinPodcast then
        local speedAdapterPod = ArrayAdapter(context, android.R.layout.simple_spinner_item, SPEED_LIST)
        speedAdapterPod.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.speedSpinPodcast.setAdapter(speedAdapterPod)
        for i, v in ipairs(SPEED_VALUES) do if v == currentSpeedValue then views.speedSpinPodcast.setSelection(i - 1) end end
        views.speedSpinPodcast.onItemSelectedListener = { onItemSelected = function(p, v, pos) currentSpeedValue = SPEED_VALUES[pos + 1]; applyPlaybackSpeed() end }
    end

    if views.speedSpinAudioSfx then
        local speedAdapterAud = ArrayAdapter(context, android.R.layout.simple_spinner_item, SPEED_LIST)
        speedAdapterAud.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.speedSpinAudioSfx.setAdapter(speedAdapterAud)
        for i, v in ipairs(SPEED_VALUES) do if v == currentSpeedValue then views.speedSpinAudioSfx.setSelection(i - 1) end end
        views.speedSpinAudioSfx.onItemSelectedListener = { onItemSelected = function(p, v, pos) currentSpeedValue = SPEED_VALUES[pos + 1]; applyPlaybackSpeed() end }
    end
    if views.fileNameInputAudioSfx then
        if savedFileName ~= "" then views.fileNameInputAudioSfx.setText(savedFileName) end
        views.fileNameInputAudioSfx.addTextChangedListener({ afterTextChanged = function(e) userFileName = e.toString(); savedFileName = userFileName; saveSettings() end })
    end
    if views.selectAudioBtn then
        views.selectAudioBtn.onClick = function()
            vibrate(30)
            showMobileAudioPickerDialog(function(item)
                if views.selectedAudioText then
                    local dTxt = (item.durationMs and item.durationMs > 0) and (" (" .. formatDurationMs(item.durationMs) .. ")") or ""
                    views.selectedAudioText.setText("Selected: " .. item.name .. dTxt)
                end
            end)
        end
    end

    if views.aiModeRadio and views.directModeRadio then
        views.aiModeRadio.setChecked(podcastGenerationMode == 1)
        views.directModeRadio.setChecked(podcastGenerationMode == 2)
        views.aiModeRadio.setOnCheckedChangeListener({
            onCheckedChanged = function(btn, isChecked) if isChecked then podcastGenerationMode = 1; saveSettings() end end
        })
        views.directModeRadio.setOnCheckedChangeListener({
            onCheckedChanged = function(btn, isChecked) if isChecked then podcastGenerationMode = 2; saveSettings() end end
        })
    end

    views.rwBtn.onClick = function() vibrate(30); jumpAudio(-10) end
    views.ffBtn.onClick = function() vibrate(30); jumpAudio(10) end
    views.playBtn.onClick = function()
        vibrate(30)
        if not generatedAudioPath then showToast("Generate audio first") return end
        if mediaPlayer == nil then
            initMediaPlayer()
            pcall(function() mediaPlayer.setDataSource(generatedAudioPath); mediaPlayer.prepare(); applyPlaybackSpeed() end)
        end
        togglePlayPause(views.playBtn)
    end
    views.downloadBtn.onClick = function() vibrate(40); downloadWithCurrentSpeed() end

    local function startActualGeneration()
        if mediaPlayer then
            if isPlaying then pcall(function() mediaPlayer.stop() end) end
            pcall(function() mediaPlayer.release() end)
            mediaPlayer = nil
        end
        deleteOldAudioFile()
        views.playBtn.setEnabled(false)
        views.playBtn.setText("PLAY")
        views.resultLayout.setVisibility(View.GONE)
        isPlaying = false
        isGenerating = true
        views.generateBtn.setEnabled(false)
        views.generateBtn.setText("GENERATING, PLEASE WAIT...")
        currentApiKeyIndex = 1
        googleApiKey = apiKeys[1]

        if isMusicMode then
            local lyrics = views.lyricsInput.getText().toString()
            local theme = views.themeInput.getText().toString()
            generateMusicWithTheme(theme, lyrics, selectedMusicStyle, getCurrentApiKey(), DEFAULT_TTS_MODEL, views.generateBtn, views.playBtn, views.resultLayout)
        elseif isPodcastMode then
            if podcastGenerationMode == 2 then
                generatePodcastDirect(userText, getCurrentApiKey(), selectedVoice, selectedVoice2, DEFAULT_TTS_MODEL, views.generateBtn, views.playBtn, views.resultLayout)
            else
                generatePodcast(userText, getCurrentApiKey(), selectedVoice, selectedVoice2, DEFAULT_TTS_MODEL, views.generateBtn, views.playBtn, views.resultLayout)
            end
        elseif isSfxMode then
            generateSfxStoryAudio(userText, selectedVoice, getCurrentApiKey(), DEFAULT_TTS_MODEL, views.generateBtn, views.playBtn, views.resultLayout)
        elseif isAudioSfxMode then
            generateAudioToSfx(selectedInputAudioPath, selectedInputAudioUri, getCurrentApiKey(), views.generateBtn, views.playBtn, views.resultLayout)
        else
            generateSingleAudio(userText, selectedVoice, getCurrentApiKey(), DEFAULT_TTS_MODEL, views.generateBtn, views.playBtn, views.resultLayout)
        end
    end

    views.generateBtn.onClick = function()
        vibrate(35)
        if isGenerating then showToast("Already generating...") return end
        loadApiKeys()
        if getCurrentApiKey() == "" then showToast("Set API key first"); showApiSettings(false); return end

        if isMusicMode then
            local lyrics = views.lyricsInput.getText().toString()
            local theme = views.themeInput.getText().toString()
            if theme == "" and lyrics == "" then showToast("Enter theme or lyrics") return end
        elseif isAudioSfxMode then
            if selectedInputAudioPath == "" and selectedInputAudioUri == nil then
                showToast("Please select an audio file first")
                return
            end
        else
            local currentText = views.textInput.getText().toString()
            if currentText == "" then showToast("Enter text") return end
            userText = currentText
        end

        if (isSfxMode or isAudioSfxMode) and not isSfxPackReady() then
            promptAndDownloadSfxPack(
                function() startActualGeneration() end,
                function() end
            )
            return
        end

        startActualGeneration()
    end

    views.hideBtn.onClick = function()
        vibrate(30)
        if isGenerating then
            appHidden = true
            hiddenGenerating = true
            mainDialog.dismiss()
            showToast("Plugin hidden, generation continues...")
        else
            showToast("No generation in progress")
        end
    end

    views.aboutBtn.onClick = function() vibrate(30); showAboutDialog() end
    views.apiBtn.onClick = function()
        vibrate(35)
        dlg.dismiss()
        delay(350, function() showApiSettings(false) end)
    end
    views.exitBtn.onClick = function() vibrate(35); dlg.dismiss(); closeAndCleanup() end
    dlg.show()
end

-- ===== STARTUP =====
loadSettings()
local firstRun = prefs.getBoolean("firstRun", true)
if (apiKeys[1] or "") == "" or firstRun then
    showApiSettings(firstRun)
else
    showMain()
end
