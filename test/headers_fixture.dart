import 'dart:io';

import 'package:archive/archive.dart';

const _ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

/// ריצה: [b] מודגש, [i] נטוי, [sup] עילי, [sz] גודל בחצאי נקודות (מאפייני הכתב המורכב).
String run(String text, {bool b = false, bool i = false, bool u = false, bool sup = false, int? sz}) {
  final pr = StringBuffer();
  if (b) pr.write('<w:b/><w:bCs/>');
  if (i) pr.write('<w:i/><w:iCs/>');
  if (u) pr.write('<w:u w:val="single"/>');
  if (sup) pr.write('<w:vertAlign w:val="superscript"/>');
  if (sz != null) pr.write('<w:sz w:val="$sz"/><w:szCs w:val="$sz"/>');
  return '<w:r><w:rPr>$pr</w:rPr><w:t xml:space="preserve">${text.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</w:t></w:r>';
}

String para(String runs, {String? style}) =>
    '<w:p>${style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>'}$runs</w:p>';

String fnRef(int id) => '<w:r><w:footnoteReference w:id="$id"/></w:r>';

const stylesXml = '<?xml version="1.0" encoding="UTF-8"?><w:styles $_ns>'
    '<w:docDefaults><w:rPrDefault><w:rPr><w:szCs w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>'
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>'
    '<w:rPr><w:b/><w:bCs/><w:szCs w:val="40"/></w:rPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="Heb2"><w:name w:val="כותרת 2"/><w:basedOn w:val="Normal"/></w:style>'
    '<w:style w:type="paragraph" w:styleId="MyOutline"><w:name w:val="Mine"/><w:basedOn w:val="Normal"/>'
    '<w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>'
    '<w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:rPr><w:szCs w:val="20"/></w:rPr></w:style>'
    '</w:styles>';

String documentXml(List<String> paras) =>
    '<?xml version="1.0" encoding="UTF-8"?><w:document $_ns><w:body>${paras.join()}</w:body></w:document>';

String footnotesXml(List<String> notes) {
  final sb = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><w:footnotes $_ns>');
  sb.write('<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>');
  for (var k = 0; k < notes.length; k++) {
    sb.write('<w:footnote w:id="${k + 1}"><w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>'
        '<w:r><w:footnoteRef/></w:r>${notes[k]}</w:p></w:footnote>');
  }
  sb.write('</w:footnotes>');
  return sb.toString();
}

/// כותב docx קטן לתיקייה זמנית ומחזיר נתיב.
String writeDocx(Directory dir, List<String> paras, {List<String> notes = const [], String name = 't.docx', bool styles = true}) {
  final a = Archive()
    ..addFile(ArchiveFile.string('word/document.xml', documentXml(paras)))
    ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'));
  if (styles) a.addFile(ArchiveFile.string('word/styles.xml', stylesXml));
  if (notes.isNotEmpty) a.addFile(ArchiveFile.string('word/footnotes.xml', footnotesXml(notes)));
  final path = '${dir.path}${Platform.pathSeparator}$name';
  File(path).writeAsBytesSync(ZipEncoder().encode(a));
  return path;
}
