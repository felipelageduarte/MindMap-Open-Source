import puppeteer from "puppeteer-core";
const CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const b=await puppeteer.launch({executablePath:CHROME,headless:"new",args:["--no-sandbox"]});
const p=await b.newPage();
const errs=[]; p.on("pageerror",e=>errs.push(e.message));
await p.goto("file://"+process.cwd()+"/index.html",{waitUntil:"networkidle0"});
await p.evaluate(()=>localStorage.clear()); await p.reload({waitUntil:"networkidle0"});
await new Promise(r=>setTimeout(r,400));

const out=await p.evaluate(async()=>{
  // spy em save()
  let saveCalls=0; const origSave=save;
  window.save=function(){ saveCalls++; return origSave.apply(this,arguments); };

  // injeta nó selecionado
  const data={nodeData:{id:"root",topic:"Teste",children:[{id:"me1",topic:"Nó",children:[]}]}};
  mind.refresh(data); await new Promise(r=>setTimeout(r,150));
  const tpc=mind.findEle("me1"); mind.selectNode(tpc);

  // spy em reshapeNode p/ depois chamar save manualmente (simula o fluxo correto)
  saveCalls=0;
  // cria imagem fake 1x1
  const canvas=document.createElement("canvas"); canvas.width=1; canvas.height=1;
  const url=canvas.toDataURL("image/jpeg",0.85);
  mind.reshapeNode(tpc,{image:{url,width:1,height:1}});
  save(); // <-- agora chamado explicitamente
  await new Promise(r=>setTimeout(r,100));

  const nodeHasImage = !!tpc.nodeObj.image && !!tpc.nodeObj.image.url;
  const dataSaved = !!mind.getData().nodeData.children.find(c=>c.id==="me1"&&c.image&&c.image.url);
  return {saveCalls, nodeHasImage, dataSaved};
});
console.log(JSON.stringify(out,null,2));
console.log("ERRORS:",errs.length?errs:"none");
await b.close();
process.exit(errs.length?1:0);
