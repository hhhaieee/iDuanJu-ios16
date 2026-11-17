import Foundation

/// Current player dialect, ported from gateway 0613b49 playersign/current*.go.
/// See HGCurrentPlayer-NOTICE.md for Apache-2.0 transform provenance.
/// Category requests retain the separate 551 dialect. No SDK/phone/token dependency.
enum HGCurrentPlayer {
    private static let profile = HGCurrentProfile.bytes
    private static let material = Array(profile[0..<32])
    private static let header = Array(profile[32..<48])
    private static let boxes = (0..<4).map { Array(profile[(48 + $0 * 256)..<(48 + ($0 + 1) * 256)]) }
    private static let initial = (0..<4).map { Array(profile[(1072 + $0 * 4)..<(1076 + $0 * 4)]) }
    private static let checksum = (0..<256).map { HGPlayerSign.rdLE64(profile, 1088 + $0 * 8) }
    private static let factorIV = (0..<8).map { le(profile,3136 + $0 * 4) }
    private static let factorTable = (0..<64).map { le(profile,3168 + $0 * 4) }
    private static let padding = Array(profile[3424..<3428])
    private static func le(_ b:[UInt8],_ at:Int)->UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at+$1]) << ($1*8) } }
    private static func be(_ b:[UInt8],_ at:Int)->UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(b[at+$1]) } }
    private static func rr(_ x:UInt32,_ n:Int)->UInt32 { let n=n&31; return x >> n | x << ((32-n)&31) }
    private static func r64(_ x:UInt64,_ n:Int)->UInt64 { let n=n&63; return x >> n | x << ((64-n)&63) }
    private static func b64(_ b:[UInt8])->String { Data(b).base64EncodedString() }
    private static func bad()->ProviderError { .invalid("当前播放器签名参数无效") }

    static func sign(pairs:[(String,String)], nowMillis:Int64, deviceID:String, versionName:String, body:[UInt8], entropy:[UInt8]? = nil) throws -> (query:String,headers:[String:String]) {
        let ent=entropy ?? (0..<24).map { _ in UInt8.random(in:0...255) }
        guard nowMillis>=1000, nowMillis<=Int64(Int32.max)*1000-128, !deviceID.isEmpty,deviceID.count<=64,!versionName.isEmpty,versionName.count<=32,ent.count==24 else { throw bad() }
        let base=pairs.filter { $0.0 != "ts" && $0.0 != "_rticket" }; let digest=HGPlayerSign.md5(body)
        for offset in Int64(0)..<128 {
            let ticket=nowMillis+offset;let t=UInt32(ticket/1000)
            let query=HGPlayerSign.encodeQuery(base+[("ts",String(t)),("_rticket",String(ticket))])
            guard query.utf8.count<=32768 else { throw bad() }
            let hash=HGPlayerSign.sm3(Array(query.utf8));let input=hash+digest+HGPlayerSign.le32(t)
            let selector=Int(HGPlayerSign.getIV(0x20230928,input)&15)
            if selector%3 != 0 { continue }
            let f=try factor(input,t,selector)
            let pb=protobuf(t,deviceID,versionName,le(ent,0),f,Array(hash.prefix(6)))
            var h=try compute(query:query,digest:digest,pb:pb,material:material,license:"646637794",aid:"8662",seconds:UInt64(t),nonce:UInt16(ent[0]) | UInt16(ent[1]) << 8,flags:0x101,
                              heliosRandom:le(ent,4),random1:le(ent,8),random2:le(ent,12),local:0x10000000,previous:le(ent,16)).headers
            h["Accept"]="application/json; charset=utf-8,application/x-protobuf";h["Content-Type"]="application/json; charset=utf-8"
            h["x-xs-from-web"]="0";h["sdk-version"]="2";h["x-ss-req-ticket"]=String(ticket);h["x-ss-stub"]=HGPlayerSign.hexStr(digest)
            return (query,h)
        }
        throw ProviderError.upstream("当前播放器签名 selector 搜索失败")
    }
    private static func protobuf(_ t:UInt32,_ did:String,_ version:String,_ nonce:UInt32,_ factor:[UInt8],_ hash:[UInt8])->[UInt8] {
        func n(_ tag:UInt32,_ v:Int64)->[UInt8] { HGPlayerSign.pSInt(tag,v) }
        func s(_ tag:UInt32,_ v:String)->[UInt8] { HGPlayerSign.pStr(tag,v) }
        var pb=HGPlayerSign.pBytes(1,header)
        pb += n(2,5)+n(3,Int64(nonce))+s(4,"8662")+s(5,did)+s(6,"646637794")
        pb += s(7,version)+s(8,"v04.10.03-ml-android")+n(9,135529984/2)
        pb += HGPlayerSign.pBytes(10,[UInt8](repeating:0,count:8))+n(12,Int64(t))
        pb += HGPlayerSign.pBytes(13,factor)+HGPlayerSign.pBytes(14,hash)
        pb += HGPlayerSign.pBytes(15,n(1,1)+n(2,1)+n(3,1))+n(17,Int64(t))+s(20,"none")+n(21,377)
        let env=n(1,100)+n(5,7)+s(6,"v04.10.03.04-bugfix")+n(7,10001)+s(14,version)
        pb += HGPlayerSign.pBytes(23,env)
        pb += s(24,#"{"cmr":16777216,"cmr2":16777216,"vpn":0,"kd":0,"dyn":"","do":0,"tk":false}"#)
        return pb
    }

    static func factor(_ input:[UInt8],_ seconds:UInt32,_ selector:Int) throws -> [UInt8] {
        guard input.count==52,[0,3,6,9,12,15].contains(selector) else { throw bad() }
        let cfg=[(15,100),(13,96),(62,94),(79,97),(66,96),(127,99)][selector/3]
        let rotation=seconds &+ UInt32(cfg.0) &- 15 &+ 0xee47628f
        let ini=factorIV.map { rr($0,Int(rotation&31)) }
        let table=factorTable.map { rr($0,Int((rotation&+1)&31)) }
        var block=input+[UInt8](repeating:0,count:12);let shift=Int((rotation&+2)&7)
        for i in 0..<4 { let x=UInt32(padding[i]);block[52+i]=UInt8(truncatingIfNeeded:x >> shift | x << ((8-shift)&7)) }
        block[62]=1;block[63]=0xa0
        var w=[UInt32](repeating:0,count:128)
        for i in 0..<16 { w[i]=be(block,i*4) }
        for i in 16..<128 {let x=w[i-15],y=w[i-2];w[i]=w[i-16] &+ (rr(x,7)^rr(x,18)^(x>>3)) &+ w[i-7] &+ (rr(y,17)^rr(y,19)^(y>>10))}
        var v=ini
        func sig(_ x:UInt32)->UInt32 {rr(x,6)^rr(x,11)^rr(x,25)}
        func upper(_ x:UInt32)->UInt32 {rr(x,2)^rr(x,13)^rr(x,22)}
        for round in 0..<cfg.1 {
            let a=v[0],b=v[1],c=v[2],d=v[3],e=v[4],f=v[5],g=v[6],h=v[7]
            let kw=table[(cfg.0+round)&63] &+ w[(cfg.0+round)&127]
            switch selector {
            case 0: let t=kw &+ (c^(e&(f^c))) &+ sig(e) &+ g;v=[t&+h,a,b,c,d,e,f,((a&b)|((b|a)&d)) &+ upper(a) &+ t]
            case 3: let t=kw &+ (h^(a&(c^h))) &+ sig(a) &+ b;v=[h,a,((f&d)|((d|f)&g)) &+ upper(f) &+ t,c,d,t&+e,f,g]
            case 6: let t=kw &+ (a^(d&(b^a))) &+ sig(d) &+ c;v=[h,a,b,((h&g)|((g|h)&f)) &+ upper(h) &+ t,d,t&+e,f,g]
            case 9: let t=kw &+ (b^(c&(f^b))) &+ sig(c) &+ d;v=[h,t&+a,b,c,((g&h)|((h|g)&e)) &+ upper(g) &+ t,e,f,g]
            case 12: let t=kw &+ (e^(b&(a^e))) &+ sig(b) &+ g;v=[t&+h,a,b,c,d,e,f,((d&f)|((f|d)&c)) &+ upper(d) &+ t]
            default: let t=kw &+ (a^(b&(d^a))) &+ sig(b) &+ f;v=[h,a,b,c,d,t&+e,((g&c)|((c|g)&h)) &+ upper(g) &+ t,g]
            }
        }
        let digest=(0..<8).flatMap { HGPlayerSign.be32(ini[$0]&+v[$0]) }
        var out=[UInt8](repeating:0,count:20)
        for i in 0..<16 {out[i]=digest[i]^digest[i+16]}
        var state:UInt32=0x20220420
        for i in 0..<8 {let x=UInt32(out[i]);state=i%2==1 ? ~(state ^ ((state<<11)|x) ^ (state>>5)) : state ^ (state<<7) ^ x ^ (state>>3)}
        out.replaceSubrange(16..<20,with:HGPlayerSign.le32((state & ~0x24)^0x01000000))
        return out
    }

    static func compute(query:String,digest:[UInt8],pb:[UInt8],material mat:[UInt8],license:String,aid:String,seconds t:UInt64,nonce:UInt16,flags:UInt16,
                        heliosRandom:UInt32,random1:UInt32,random2:UInt32,local:UInt64,previous:UInt32) throws -> (headers:[String:String],state:UInt32) {
        guard mat.count==32,digest.count==16,(2...32768).contains(pb.count) else { throw bad() }
        var crc:UInt64=0
        for ch in license.utf8 { crc=checksum[Int(UInt8(truncatingIfNeeded:crc)^ch)]^(crc>>8) }
        let state=UInt32(truncatingIfNeeded:r64(crc^t^local,60))^previous
        let h=["x-khronos":String(t),"x-argus":b64(HGPlayerSign.le32(UInt32(truncatingIfNeeded:t))),"x-ladon":b64(HGPlayerSign.be32(state)),
               "x-gorgon":gorgon(query,digest,t,nonce,flags),"x-helios":helios(t,license,aid,heliosRandom),"x-medusa":try medusa(pb,mat,t,random1,random2)]
        return (h,state)
    }
    private static func gorgon(_ query:String,_ digest:[UInt8],_ t:UInt64,_ nonce:UInt16,_ flags:UInt16)->String {
        let key:[Int]=[0x4a,Int(flags&255),0x16,Int(nonce>>8),0x47,0x6c,Int(flags>>8),Int(nonce&255)]
        var table=Array(0...255);var j=0
        for i in 0..<256 {j=(j+table[i]+key[i%8])&255;table[i]=table[j]}
        let seed=Array(HGPlayerSign.md5(Array(query.utf8)).prefix(4))+Array(digest.prefix(4))+[UInt8](repeating:0,count:4)+[0,9,9,4]+HGPlayerSign.be32(UInt32(truncatingIfNeeded:t))
        var out=[UInt8](repeating:0,count:20);j=0
        for n in 0..<20 {let i=n+1;j+=table[i&255];let y=table[j&255];table[i&255]=y;out[n]=seed[n]^UInt8(table[(y+y)&255])}
        for i in 0..<20 {let x=out[i];let swapped=(x>>4)|(x<<4);let v=out[(i+1)%20]^swapped;var reverse:UInt8=0;for b in 0..<8 {reverse |= ((v>>b)&1) << (7-b)};out[i] = ~(reverse^20)}
        return HGPlayerSign.hexStr([0x84,4,UInt8(truncatingIfNeeded:nonce),UInt8(nonce>>8),UInt8(truncatingIfNeeded:flags),UInt8(flags>>8)]+out)
    }
    private static func helios(_ t:UInt64,_ license:String,_ aid:String,_ random:UInt32)->String {
        let key=Array(HGPlayerSign.hexStr(HGPlayerSign.md5(HGPlayerSign.le32(random)+Array(aid.utf8))).utf8)
        var keys=[UInt64](repeating:0,count:35);keys[0]=HGPlayerSign.rdLE64(key,0)
        var a=keys[0],b=HGPlayerSign.rdLE64(key,8);var queue=[HGPlayerSign.rdLE64(key,16),HGPlayerSign.rdLE64(key,24)]
        for i in 0..<34 {var x=(r64(b,8)&+a)^UInt64(i);queue.append(x);x ^= r64(a,61);keys[i+1]=x;a=x;b=queue.removeFirst()}
        let raw=Array("\(t)-\(license)-\(aid)".utf8);let n=16-raw.count%16;let plain=raw+[UInt8](repeating:UInt8(n),count:n)
        var out=HGPlayerSign.le32(random)
        for at in stride(from:0,to:plain.count,by:16) {var l=HGPlayerSign.rdLE64(plain,at),r=HGPlayerSign.rdLE64(plain,at+8);for i in 0..<34 {r=keys[i]^(l&+r64(r,8));l=r^r64(l,61)};out+=HGPlayerSign.wrLE64(l)+HGPlayerSign.wrLE64(r)}
        return b64(out)
    }
    private static func ks(_ pb:[UInt8],_ mat:[UInt8],_ t:[UInt8])->[UInt8] {
        let box=HGPlayerSign.sm3(mat+t+mat);let n=pb.count;var b=[UInt8](repeating:0,count:n)
        for i in pb.indices {let a=UInt32(box[4*i%32]),c=UInt32(box[(4*i+1)%32]),x=UInt32(pb[i]);let w = ~(((x>>4)|(x<<4)) &+ a ^ c);let rot=((w<<3)&0xfffffff8)|((w>>5)&7);b[n-1-i]=UInt8(truncatingIfNeeded:~(a^(rot&+c)))}
        let last=b[n-1],prev=b[n-2];b[0] &+= ~(last^prev);b[1]=(b[0]^last^254)&+b[1]
        for j in 2..<(n-1) {let v=UInt32(b[j-1]);let rot=((v>>5)&7)|(v<<3);b[j] &+= UInt8(truncatingIfNeeded:~(UInt32(b[j-2])^rot^UInt32(j)))}
        b[n-1] ^= b[n-2];let sum=b.dropFirst().reduce(UInt8(0),&+);b[0]=(b[0]^b[1])&+sum
        let reg = ~(((UInt32(t[2])<<11)|UInt32(t[3])) ^ UInt32(t[2]) ^ UInt32(t[2]>>5))
        let mask=HGPlayerSign.be32(reg);let stream=[UInt8](repeating:0,count:8)+b
        return stream.indices.map { mask[$0%4]^stream[stream.count-1-$0] }
    }
    private static let con=[[2,0,3,1],[1,3,2,0],[3,2,1,0],[2,3,1,0]]
    private static let order=[[0,9,14,15,4,13,2,7,8,1,6,3,12,5,10,11],[0,9,14,11,4,13,2,3,8,1,6,15,12,5,10,7],[0,9,14,3,4,13,2,15,8,1,6,11,12,5,10,7],[0,9,14,15,4,13,2,3,8,1,6,11,12,5,10,7]]
    static func transform(_ plain:[UInt8],_ key:[UInt8],_ iv:[UInt8],_ branch:Int) throws -> [UInt8] {
        guard key.count==16,iv.count==16,(0...3).contains(branch) else {throw bad()}
        var expanded=[UInt8](repeating:0,count:48);let box=boxes[branch];let ini=le(initial[branch],0)
        for i in 0..<16 {expanded[i]=key[i]^initial[branch][i%4]}
        var rounds=8
        for i in 4..<12 {let at=4*(i-1);var a=expanded[at],b=expanded[at+1],c=expanded[at+2],d=expanded[at+3]
            if i&3==0 {let old=a;a=UInt8(truncatingIfNeeded:(ini>>(rounds&24))^UInt32(box[Int(b)]));b=box[Int(c)];c=box[Int(d)];d=box[Int(old)]}
            rounds+=2;for (j,v) in [a,b,c,d].enumerated() {expanded[at+4+j]=v^expanded[at-12+j]}}
        let pad=16-plain.count%16;let source=plain+[UInt8](repeating:UInt8(pad),count:pad);var previous=iv;var out=[UInt8]();let co=con[branch]
        for at in stride(from:0,to:source.count,by:16) {
            var state = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 {
                let keyIndex: Int = 4 * (i / 4) + co[i % 4]
                state[i] = source[at + i] ^ previous[i] ^ expanded[keyIndex]
            }
            for round in 1...2 {
                var old = state
                for i in 0..<16 {
                    let index: Int = co[i / 4] * 4 + i % 4
                    state[i] = box[Int(old[index])]
                }
                old = state
                for i in 0..<16 { state[i] = old[order[branch][i]] }
                if round==1 {
                    old=state
                    for i in 0..<16 {
                        let index: Int = 4 * (i / 4) + co[i % 4]
                        state[i] = old[index]
                    }
                    for j in 0..<4 {let total=state[j]^state[4+j]^state[8+j]^state[12+j];let first=state[j]
                    for i in 0..<4 {let next=i<3 ? state[(i+1)*4+j] : first;let x=state[i*4+j]^next;let xt=(x<<1)^(x&128 != 0 ? 0x1b:0);state[i*4+j] ^= total^xt}}}
                for i in 0..<16 {state[i] ^= expanded[16*round+4*(i/4)+co[i%4]]}}
            previous=(0..<16).map {state[$0]^expanded[16+$0]};out+=previous}
        return out
    }
    private static func mid(_ pb:[UInt8]) throws -> UInt16 {
        var at=0;var first=[Int](repeating:-1,count:2)
        func read() throws -> UInt64 {var v:UInt64=0;for i in 0..<10 {guard at<pb.count else {throw bad()};let b=pb[at];at+=1;guard i<9 || b<=1 else {throw bad()};v |= UInt64(b&127) << (7*i);if b&128==0 {return v}};throw bad()}
        while at<pb.count {let tag=try read();guard tag>>3 != 0 else {throw bad()};switch tag&7 {
        case 0:_ = try read()
        case 1:at+=8
        case 5:at+=4
        case 2:let n64=try read();guard n64<=UInt64(pb.count-at) else {throw bad()};let n=Int(n64),field=Int(tag>>3);if (13...14).contains(field),n>0 {first[field-13]=Int(pb[at])};at+=n
        default:throw bad()
        };guard at<=pb.count else {throw bad()}}
        guard first.allSatisfy({$0>=0}) else {throw bad()};return UInt16(first[0]&63)|UInt16(first[1]&63)<<6
    }
    private static func medusa(_ pb:[UInt8],_ mat:[UInt8],_ t:UInt64,_ r1:UInt32,_ r2:UInt32) throws -> String {
        let m=try mid(pb),t4=HGPlayerSign.le32(r1);var prefix:UInt32=0
        for i in mat.indices {let x=UInt32(mat[i]);prefix=i%2==0 ? prefix^(prefix<<7)^x^(prefix>>3) : prefix ^ ~((prefix<<11)^x^(prefix>>5))}
        var pre=[UInt8(truncatingIfNeeded:prefix)]+HGPlayerSign.le32(r2)
        pre += [1,UInt8(truncatingIfNeeded:m),UInt8(m>>8),0x18]
        pre += ks(pb,mat,t4)+Array(t4[2..<4])
        guard pre.count>=248 else {throw bad()}
        let lane=[6,5,3,4,2,7,1,0],bits=[1,7,3,6,2,0,4,5];var plain=[UInt8](repeating:0,count:31)
        for i in 0..<248 {plain[i/8] |= ((pre[i]>>lane[i%8])&1)<<bits[i%8]}
        let channel=try transform(plain,HGPlayerSign.md5(Array(mat[0..<16])),HGPlayerSign.md5(Array(mat[16..<32])),Int(t&3));var body=pre
        for i in 0..<248 {body[i]=(body[i] & ~(1<<lane[i%8])) | (((channel[i/8]>>bits[i%8])&1)<<lane[i%8])}
        var hdr=HGPlayerSign.le32(5)+header;let mask=HGPlayerSign.le32(UInt32(truncatingIfNeeded:t))
        for i in hdr.indices {hdr[i] ^= mask[i%4]}
        return b64(hdr+Array(t4.prefix(2))+[0,1,channel[31]]+body)
    }
}
