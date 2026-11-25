# work-tools

İş ve sistem bakımı süreçlerinde kullanılan Windows araçları ve otomasyon betikleri.

## Araçlar

| Araç | Açıklama | Çalıştırma |
| --- | --- | --- |
| `autodesk_tam_temizle/` (`autodesk_tam_temizle.zip`) | Tüm Autodesk ürünlerinin (Revit, AutoCAD, 3ds Max, Access, lisans servisi vb.) kayıt defteri yedeği alınarak tam temizliği | Arşivi ayıklayın, `autodesk_tam_temizle.bat` dosyasına sağ tık → **Yönetici olarak çalıştır** |
| `revit2024_temizle.bat` (`revit2024_temizle.zip`) | Revit 2024 kalıntı temizleme betiği (masaüstüne kayıt defteri yedeği alır) | Sağ tık → **Yönetici olarak çalıştır** |
| `solidworks_tam_temizle.bat` | SolidWorks (2024 ve türevleri: eDrawings, PDM, Electrical, Visualize, Simulation vb.) için kayıt defteri yedeği ve log alarak tam temizlik (kişisel modellere dokunmaz) | Çift tıklayın (yönetici iznini otomatik ister) |
| `python-guncelle.bat` | Mevcut Python sürümlerini sessizce kaldırır, `python.org` üzerinden en güncel kararlı 64-bit Python sürümünü indirip tüm kullanıcılar için PATH'e ekleyerek kurar | Çift tıklayın (yönetici iznini otomatik ister) |
| `yazici-duzelt.bat` | Yazıcı çöp karakter sorunları için menülü araç (Spooler sıfırlama, yazıcı/port listeleme, sürücü kaldırma, standart TCP/IP port ekleme, yazıcı ekleme ve test sayfası) | Çift tıklayın (yönetici iznini otomatik ister) |
| `program-envanteri.bat` | Bilgisayardaki tüm kurulu programları, CAD/CAM/mühendislik yazılımlarını ve eklentilerini (SolidWorks, SolidCAM, ANSYS/SpaceClaim, Autodesk/Revit/Inventor, MATLAB, Rhino, SketchUp, Blender), Visual Studio (sürüm, iş yükleri, VSIX), VS Code / Cursor / Windsurf eklentilerini, JetBrains/Arduino, Office (COM/VSTO), Adobe, tarayıcı eklentilerini ve geliştirici araçlarını sürümleriyle tarar; Masaüstüne aranabilir **HTML**, düz metin **TXT** ve Excel uyumlu **CSV** rapor üretir | Çift tıklayın (yönetici izni şart değildir; yönetici olarak çalıştırılırsa diğer kullanıcı profilleri de taranır) |
