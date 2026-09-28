// Fake WDF Tracker: same response shapes as /api/graduate/{login,me,students}.
const http = require('http');
const grads = {
  '0820000001': { id: 'gradA', name: 'Precious Mahlangu', pw: 'secret1', status: 'ACCEPTED', acceptedCompany: 'MONARCH', churchId: 'chA', church: 'Bethel Assembly' },
  '0820000002': { id: 'gradB', name: 'Wdf Person', pw: 'secret2', status: 'ACCEPTED', acceptedCompany: 'WDF', churchId: 'chB', church: 'Other Church' },
  '0820000003': { id: 'gradC', name: 'Sibusiso Wdf', pw: 'secret3', status: 'ACCEPTED', acceptedCompany: 'WDF', churchId: 'chA', church: 'Bethel Assembly' },
  '0820000004': { id: 'gradD', name: 'Still Applying', pw: 'secret4', status: 'APPLIED', acceptedCompany: null, churchId: 'chD', church: 'New Hope Church' },
  '0820000005': { id: 'gradE', name: 'Was Rejected', pw: 'secret5', status: 'REJECTED', acceptedCompany: null, churchId: 'chE', church: 'Rejected Church' },
};
const students = {
  chA: [
    { id: 'en1', memberId: 'mem1', name: 'Ayanda Mthembu', contact: '0711111111', skill: 'Home Based Care', modules: ['Business Management', 'Financial Literacy', 'Job Readiness', "Learners & Driver's Licence"] },
    { id: 'en2', memberId: 'mem2', name: 'Refilwe Baloyi', contact: '0722222222', skill: 'Music / Dance / Art', modules: ['Business Management'] },
    { id: 'en3', memberId: null, name: 'Loose Record', contact: '0733333333', skill: 'Retail Management', modules: [] },
  ],
};
const byToken = {};
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const send = (s, j) => { res.writeHead(s, { 'content-type': 'application/json' }); res.end(JSON.stringify(j)); };
    const tok = (req.headers.authorization || '').replace('Bearer ', '');
    if (req.url === '/api/graduate/login') {
      const b = JSON.parse(body || '{}'); const g = grads[b.identifier];
      if (!g || g.pw !== b.password) return send(401, { error: 'Cell/email or password is incorrect.' });
      const t = 'tok_' + g.id; byToken[t] = g; return send(200, { graduateId: g.id, name: g.name, token: t });
    }
    const g = byToken[tok];
    if (!g) return send(401, { error: 'Not logged in.' });
    if (req.url === '/api/graduate/me') return send(200, { id: g.id, name: g.name, status: g.status, company: g.acceptedCompany, churchName: g.church }); // real /me shape
    if (req.url === '/api/graduate/students') {
      if (g.acceptedCompany !== 'MONARCH') return send(403, { error: 'Only a chosen Monarch graduate heads the curriculum.' });
      return send(200, { total: 3, students: students[g.churchId] || [] });
    }
    send(404, { error: 'nope' });
  });
}).listen(8799, () => console.log('mock tracker on 8799'));
