# NESEmu - محاكي نينتندو NES لـ iOS

محاكي NES مكتوب بالكامل بـ Swift/SwiftUI، مبني ليتم تجميعه إلى `.ipa` تلقائيًا عبر GitHub Actions بدون الحاجة لجهاز Mac.

## الحالة الحالية
- ✅ محاكي CPU (6502) كامل — كل الأوامر الرسمية (official opcodes)
- ✅ PPU محسّن — تمرير أفقي ورأسي، عبور Nametable، حد 8 sprites لكل scanline، أولوية sprites وSprite‑0 hit
- ✅ Mapper 0 (NROM) فقط — يغطي ألعاب زي Donkey Kong, Super Mario Bros, Balloon Fight
- ✅ واجهة SwiftUI بها زر تحميل ROM + كنترولر افتراضي على الشاشة
- ❌ لا يوجد صوت APM بعد
- ❌ لا يوجد Mappers إضافية (MMC1, MMC3...) بعد
- ⚠️ التوقيت (timing) ما زال مبسّطًا مقارنة بمحاكيات NES المكتملة، لكن تشوه وتكرار البلاطات الناتج عن تجاهل scroll تم إصلاحه

## كيف تبني الـ .ipa (بدون Mac)
1. ارفع هذا المجلد كامل لريبو GitHub جديد
2. روح لتبويب **Actions** في الريبو، فعّل الـ workflow (أو اعمل push لـ main)
3. بعد ما يخلص البناء (~5-10 دقائق)، حمّل الملف `NESEmu-ipa` من الـ Artifacts
4. فك الضغط تحصل على `NESEmu.ipa`

## كيف تثبته على جهازك
1. حمّل [Sideloadly](https://sideloadly.io/) على وندوز
2. وصّل جهاز iOS بالكيبل
3. اسحب `NESEmu.ipa` إلى Sideloadly، سجل دخول بـ Apple ID (مجاني)، اضغط Start
4. في الجهاز: Settings > General > VPN & Device Management > وثّق التطبيق

⚠️ التطبيقات الموقّعة بحساب Apple ID مجاني تنتهي صلاحيتها كل 7 أيام، تحتاج تعيد التثبيت.

## إضافة ROMs
افتح التطبيق واضغط "فتح ملف ROM"، اختر ملف `.nes` من جهازك (عبر Files app). تقدر تنقل الملفات للتطبيق عبر iTunes File Sharing أو AirDrop لأن `UIFileSharingEnabled` مفعّل.

## الخطوات الجاية المقترحة
- إضافة APU (الصوت)
- إضافة Mapper 1 (MMC1) و Mapper 4 (MMC3) لتغطية أكبر عدد ألعاب
- تحسين دقة توقيت الـ PPU (scanline-accurate rendering بدل frame-at-once)
- حفظ/استرجاع الحالة (save states)
