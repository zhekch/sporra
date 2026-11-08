// Fixture-only host for the Flutter native rail integration test. No database.
import { createServer } from 'node:http';
import { reference } from '../../server/render-reference.js';
const port = Number(process.env.PORT || 3217);
createServer(async (req,res)=>{
  try {
    const data = await reference('rail',`http://127.0.0.1:${port}`,'airline',null,{native:true});
    res.setHeader('Content-Type','application/json');
    res.end(JSON.stringify(data));
  } catch(e) { res.statusCode=500;res.end(JSON.stringify({error:e.message})); }
}).listen(port,'127.0.0.1',()=>console.log(`Rail fixture listening on ${port}`));
